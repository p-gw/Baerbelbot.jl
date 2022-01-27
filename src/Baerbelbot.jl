using Discord, Dates, DataFrames, LibPQ, DotEnv, Cairo, Fontconfig

DotEnv.config()

include("./startup.jl")

const token = string(ENV["BOT_TOKEN"])
const c = Client(token)

set_prefix!(c, "!")

add_command!(c, Symbol("bärbel wann")) do c, msg
  reference = Dates.DateTime(2020, 7, 16, 19, 0, 0)
  current = Dates.now()
  upcoming = reference

  while upcoming < current
    upcoming += Dates.Week(1)
  end

  difference = Dates.canonicalize(Dates.CompoundPeriod(upcoming - current)) |> string
  difference = translate(difference)
  response = "Und da steigt die Lust auf ein :beer:! Noch $(difference) bis zum nächsten Stammtisch"
  reply(c, msg, response)
end

add_command!(c, Symbol("bärbel zähl"), parsers = [String]) do c, msg, user
  user_id = uid(user)
  data = pull(db)

  if user == "alle"
    amount = sum(data.amount)
    min_date = Dates.format(min(data.timestamp...), "d.m.yyyy")
    reply(c, msg, "Seit $(min_date) wurden insgesamt $(amount) Biere getrunken.")
  elseif user_id in string.(data.uid) || user == ""
    ids = findall(x -> x == user_id, string.(data.uid))
    df = data[ids, :]
    amount = sum(df.amount)
    n_days = length(unique(Dates.format.(df.timestamp, "d.m.yyyy")))
    avg = round(average(df), digits = 2)
    min_date = Dates.format(min(df.timestamp...), "d.m.yyyy")
    reply(c, msg, "$(user) hat seit $(min_date) insgesamt $(amount) Biere getrunken (Ø $(avg)).")
  else
    reply(c, msg, "Da hat wohl jemand noch kein Bier getrunken...")
  end
end

add_command!(c, Symbol("bärbel plus"), parsers = [String, Splat(String, ",")]) do c, msg, beers, users...
  users = collect(users)
  amount = count(beers)

  for user in users
    push!(db, uid(user), amount)
    reply(c, msg, "$amount Bier$(amount > 1 ? "e" : "") für $(user) hinzugefügt.")
  end
end

add_command!(c, Symbol("bärbel minus"), parsers = [String, Splat(String, ",")]) do c, msg, beers, users...
  users = collect(users)
  amount = count(beers)

  for user in users
    push!(db, uid(user), -amount)
    reply(c, msg, "$amount Bier$(amount > 1 ? "e" : "") für $(user) entfernt.")
  end
end

add_command!(c, Symbol("bärbel rangliste")) do c, msg
  data = pull(db)
  data = data[data.uid .!= "offset", :]
  rankings = combine(groupby(data, :uid), :amount => sum)
  sort!(rankings, :amount_sum, rev = true)
  rankings.rank = collect(1:nrow(rankings))
  rankings.uid = string.(rankings.uid)
  rankings.uid = enquote.(rankings.uid)

  response = "**Rangliste**\n"
  for r in eachrow(rankings)
    response *= "$(r.rank). $(r.uid) ($(r.amount_sum) :beer:)\n"
  end

  reply(c, msg, response)
end

function beer_handler(c::Client, e::MessageCreate)
  if !occursin("!bärbel", e.message.content)
    user = e.message.author
    message = e.message.content
    amount = count(message)

    if amount > 0
      create(c, Reaction, e.message, '👍')
      reply(c, e.message,  "Prost $(user)! Habe $amount Bier$(amount > 1 ? "e" : "") hinzugefügt.")
      push!(db, uid(string(user.id)), amount)
    end
  end
end

add_handler!(c, MessageCreate, beer_handler)

add_command!(c, Symbol("bärbel menü")) do c, msg
  mains = ["Schnitzel", "Cordon Bleu"]
  sides = ["Salat", "Braterdäpfel", "Petersilerdäpfel", "Pommes"]
  selectedMain = rand(mains)
  selectedSide = rand(sides)
  extraPomm = selectedSide == "Pommes" ? ""  : "\nVielleicht Pommes dazu?"
  response = "Als Hauptspeise kann ich heute $(selectedMain) mit $(selectedSide) empfehlen.$(extraPomm)"
  reply(c, msg, response)
end

add_command!(c, Symbol("bärbel 💉")) do c, msg
  vaccination_date = Dates.Date(2021, 7, 12)
  days_til_vaccination = vaccination_date - today()
  response = "Nur noch $(days_til_vaccination.value) Tage bis zur Impfung!"
  reply(c, msg, response)
end

const server_start = Dates.now()

add_command!(c, Symbol("bärbel uptime")) do c, msg
  uptime = string(Dates.now() - server_start)
  reply(c, msg, uptime)
end

add_command!(c, Symbol("bärbel miss"), parsers = [Float64, Float64], fallback_parsers = (c, msg) -> reply(c, msg, "Bitte gib dein Gewicht (kg) und das Messergebnis (mm) als Zahl an!"), help = "test") do c, msg, weight, measurement
  percentage = 100 * (weight - (10.26 + 0.7927 * weight - 0.3676 * measurement)) / weight
  emoji = percentage < 8 ? ":ruppeobenohne:" : percentage < 20 ? ":hirschisexy:" : percentage < 25 ? ":ohmygod:" : ":assidead:"
  response = "Spieglein, Spieglein an der Wand, wer ist der Dickste im ganzen Land?\nBei einem Körpergewicht von $(weight)kg hast du einen Körperfettanteil von $(round(percentage, digits = 1))%! $(emoji)"
  reply(c, msg, response)
end

add_command!(c, Symbol("bärbel prophezeie"), parsers = [Splat(String)]) do c, msg, users...
  user_ids = uid.(users)
  @fetch begin
    user_data = [retrieve(c, User, parse(Int, user)).val for user in user_ids]
  end

  data = pull(db)
  identical_data = checksum(data) == checksum("data/data.csv")
  if identical_data
    predictions = CSV.read("data/predictions.csv", DataFrame)
    predictions.uid = string.(predictions.uid)
    chain = h5open("data/mcmc-chains.h5", "r") do f
      read(f, Chains)
    end
  else
    reply(c, msg, "Hm, schwer zu sagen... Da muss ich noch einmal nachrechnen.")
    chain, predictions = forecast(data)
    save!(chain)
    save!(pull(db), "data.csv")
    save!(predictions, "predictions.csv")
  end

  filter!(x -> x.uid in user_ids, predictions)

  # user ids are replaced by usernames for plotting
  replacements = []
  for i in 1:length(user_ids)
    Base.push!(replacements, user_ids[i] => user_data[i].username)
  end
  predictions.username = replace(predictions.uid, replacements...)

  p = plot_forecast(predictions, chain)
  p |> PNG("data/plot.png", 15cm, 10cm, dpi = 250)

  channel_future = get_channel(c, msg.channel_id)
  channel = fetch(channel_future).val
  upload_file(c, channel, "data/plot.png")
end

open(c)
wait(c)
