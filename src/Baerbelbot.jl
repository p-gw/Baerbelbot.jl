module Baerbelbot

using Discord, Dates, DataFrames, LibPQ, DotEnv

DotEnv.config()

function push!(connection, uid, amount::Int, ts = Dates.now())
  execute(connection, "INSERT INTO data (timestamp, uid, amount) VALUES('$(ts)', '$(uid)', '$(amount)')")
end

function pull(connection)
  result = execute(connection, "SELECT * FROM data")
  return DataFrame(result)
end

const token = string(ENV["BOT_TOKEN"])
const c = Client(token)
const db = LibPQ.Connection("""
  host=$(ENV["DATABASE_HOST"])
  port=$(ENV["DATABASE_PORT"])
  user=$(ENV["DATABASE_USER"])
  password=$(ENV["DATABASE_PASSWORD"])
  dbname=$(ENV["DATABASE_NAME"])
""")


set_prefix!(c, "!")

function translate(t::String)
  t = replace(t, "days" => "Tage")
  t = replace(t, "day" => "Tag")
  t = replace(t, "hours" => "Stunden")
  t = replace(t, "hour" => "Stunde")
  t = replace(t, "minutes" => "Minuten")
  t = replace(t, "minute" => "Minute")
  t = replace(t, " seconds" => " Sekunden")
  t = replace(t, " second" => " Sekunde")
  t = replace(t, "milliseconds" => "Millisekunden")
  t = replace(t, "millisecond" => "Millisekunde")
end

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

function uid(user::String)::String
  replace(user, r"[^0-9]" => s"")
end

function average(d::AbstractDataFrame)::Float64
  total = sum(d.amount)
  n_days = length(unique(Dates.format.(d.timestamp, "d.m.yyyy")))
  return total / n_days
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

function count(s::String)::Int
  length(split(s, r"🍺")) - 1
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

function enquote(s::String)
  return "<@" * s * ">"
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
      pushData(db, uid(string(user.id)), amount)
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

const server_start = Dates.now()

add_command!(c, Symbol("bärbel uptime")) do c, msg
  uptime = string(Dates.now() - server_start)
  reply(c, msg, uptime)
end

open(c)
wait(c)

end # module
