using LibPQ, Turing, Distributions, LazyArrays, CategoricalArrays, ReverseDiff, Memoization, StatsFuns, Random

function prediction_data(data::DataFrame)
  filter!(x -> x.uid != "offset", data)
  data.date = Date.(data.timestamp)
  data.year = year.(data.date)
  data.week = week.(data.date)
  weekly_data = combine(groupby(data, [:uid, :year, :week]), :amount => sum => :amount)

  # if any amount is negative treat it as a correction for the previous week
  for i in findall(x -> x < 0, weekly_data.amount)
    user = weekly_data[i, :uid]
    year = weekly_data[i, :year]
    previous_week = weekly_data[i, :week] - 1
    ind = findfirst(x -> x.uid == user && x.year == year && x.week == previous_week, eachrow(weekly_data))
    weekly_data[ind, :amount] += weekly_data[i, :amount]
  end

  delete!(weekly_data, findall(x -> x < 0, weekly_data.amount))

  weekly_data.date = @. Date(weekly_data.year) + Week(weekly_data.week)
  weekly_data.date += @. Day(4 - dayofweek(weekly_data.date))

  first_date = minimum(weekly_data.date)
  weekly_data.t = @. round(weekly_data.date - first_date, Week(1)) + Week(1)
  weekly_data.t = [t.value for t in weekly_data.t]

  possible_ts = minimum(weekly_data.t):maximum(weekly_data.t)

  for uid in unique(weekly_data.uid)
    for t in possible_ts
      matched = findfirst(x -> x.uid == uid && x.t == t, eachrow(weekly_data))
      if isnothing(matched)
        insert_date = first_date + Week(t)
        insert_row = DataFrame(uid = uid, year = year(insert_date), week = week(insert_date), amount = 0, date = insert_date, t = t)
        weekly_data = vcat(weekly_data, insert_row)
      end
    end
  end

  sort!(weekly_data, [:uid, :date])
  weekly_data = combine(groupby(weekly_data, :uid), :amount => cumsum => :cum_amount, :year, :week, :amount, :date, :t)

  weekly_data.person_id = convert.(Int, categorical(weekly_data.uid).refs)
  return weekly_data
end

struct ZILogPoisson{ T } <: DiscreteUnivariateDistribution
  θ::T
  λ::T
end

function Distributions.logpdf(d::ZILogPoisson, y::Int)
  θ, λ = d.θ, d.λ
  if y == 0
    ll = [
      logpdf(BernoulliLogit(θ), 1),
      logpdf(BernoulliLogit(θ), 0) + logpdf(LogPoisson(λ), y)
    ]
    return logsumexp(ll)
  else
    ll = logpdf(BernoulliLogit(θ), 0) + logpdf(LogPoisson(λ), y)
    return ll
  end
end

function Distributions.rand(rng::AbstractRNG, d::ZILogPoisson)::Int
  θ, λ = d.θ, d.λ
  c = rand(rng, BernoulliLogit(θ))
  return c == 1 ? 0 : rand(rng, LogPoisson(λ))
end

Distributions.minimum(::ZILogPoisson) = 0
Distributions.maximum(::ZILogPoisson) = Inf

@model function ZIPoisReg(y, t, person_ids; n = length(y), n_t = length(unique(t)), n_person = length(unique(person_ids)))
  # predictors for poisson expectation
  a_0 ~ Normal(log(2.5), log(2.0))
  σ_a_person ~ truncated(Normal(), 0, Inf)
  a_person ~ filldist(Normal(0, σ_a_person), n_person)
  σ_t ~ truncated(Normal(), 0, Inf)
  a_t ~ filldist(Normal(0, σ_t), n_t)

  # predictors for mixing probability
  b_0 ~ Normal(logit(0.1), 1)
  σ_b_person ~ truncated(Normal(), 0, Inf)
  b_person ~ filldist(Normal(0, σ_b_person), n_person)

  y ~ arraydist(LazyArray(@~ @. ZILogPoisson(
    b_0 + b_person[person_ids],
    a_0 + a_person[person_ids] + a_t[t]
  )))
end

function forecast_1step(chain, person_id)
  df = DataFrame(chain)
  a_t = @. rand(Normal(0, df[:, :σ_t]))
  y_pred = @. rand(ZILogPoisson(
    df[:, :b_0] + df[:, Symbol("b_person[$person_id]")],
    df[:, :a_0] + df[:, Symbol("a_person[$person_id]")] + a_t)
  )
  return y_pred
end

function forecast_nsteps(chain, person_id, n_steps)
  predictions = Matrix{Int}(undef, n_steps, 2000)
  for i in 1:n_steps
    predictions[i, :] = forecast_1step(chain, person_id)
  end
  return predictions
end

function forecast(chain, data, uid::String, n_steps)
  person_data = filter(x -> x.uid == uid, data)
  person_id = first(unique(person_data.person_id))

  predictions = forecast_nsteps(chain, person_id, n_steps)
  max = fill(maximum(person_data.cum_amount), 1, 2000)  # add this for offset and plotting
  predictions = vcat(max, predictions)
  cum_predictions = cumsum(predictions, dims = 1)

  result = DataFrame(
    person_id = person_id,
    uid = uid,
    lwr = [quantile(cum_predictions[i, :], .1) for i in 1:n_steps + 1],
    md = [quantile(cum_predictions[i, :], .5) for i in 1:n_steps + 1],
    upr = [quantile(cum_predictions[i, :], .9) for i in 1:n_steps + 1],
    t = maximum(person_data.t):maximum(person_data.t) + n_steps,
    date = maximum(person_data.date):Week(1):maximum(person_data.date) + Week(n_steps)
  )

  return result
end

function forecast(data::DataFrame; to = endofyear(), algorithm = NUTS(0.65), I = 2000)
  data = prediction_data(data)
  # model fit
  model = ZIPoisReg(data.amount, data.t, data.person_id)
  chain = sample(model, algorithm, I)

  # calculate forecast ranges
  forecasts = []
  for uid in unique(data.uid)
    from = maximum(data[data.uid .== uid, :date])
    forecast_range = from:Week(1):to
    forecast_length = length(forecast_range)
    Base.push!(forecasts, forecast(chain, data, uid, forecast_length))
  end

  forecast_df = vcat(data, forecasts..., cols = :union)
  filter!(x -> x.date <= to, forecast_df)
  return chain, forecast_df
end

function save_forecast!(chain, df)
  # save chains
  h5open("data/mcmc-chains.h5", "w") do f
    write(f, chain)
  end
  # save forecasted data
  open("data/data.csv", "w") do f
    CSV.write(f, df)
  end
  return nothing
end

function read_forecast(; chain = "data/mcmc-chains.h5", df = "data.csv")
  saved_chain = h5open(chain, "r") do f
    read(f, Chains)
  end
  saved_df = open(df, "r") do f
    tmp = CSV.read(f, DataFrame)
    tmp.uid = string.(tmp.uid)
  end
  return saved_chain, saved_df
end

function missing_probability(chain::Chains, person_id::Int)
  df = DataFrame(chain)
  b_0 = df.b_0
  b_person = df[:, Symbol("b_person[$person_id]")]
  prob = @. logistic(b_0 + b_person)
  return mean(prob)
end

function plot_forecast(data::DataFrame, chain::Chains)
  p = plot(data, x = :date, y = :cum_amount, color = :username, Geom.line,
    Guide.xlabel("Datum"),
    Guide.ylabel("Anzahl Bier"),
    Guide.colorkey(title = "")
  )
  Gadfly.push!(p, layer(y = :md, ymin = :lwr, ymax = :upr, color = :username, alpha = [0.5], Geom.path, Geom.ribbon))

  # for single persons add statistics
  if length(unique(data.person_id)) == 1
    person_id = first(data.person_id)
    predictions = data[ismissing.(data.amount), :]
    upcoming = round(Int, predictions[2, :md] - predictions[1, :md])
    p_attend = round((1 - missing_probability(chain, person_id)), digits = 2)
    Gadfly.push!(p,
      Guide.annotation(compose(context(),
        Compose.text(0.5cm, 0.8cm, "E(Bier | anwesend) = $(upcoming)"),
        fill(Gadfly.RGB(0.627,0.627,0.627)), Compose.stroke(nothing), fontsize(9pt)
      )),
      Guide.annotation(compose(context(),
        Compose.text(0.5cm, 1.3cm, "P(anwesend) = $(p_attend)"),
        fill(Gadfly.RGB(0.627,0.627,0.627)), Compose.stroke(nothing), fontsize(9pt)
      ))
    )
  end

  return p
end
