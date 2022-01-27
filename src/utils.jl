using Dates, DataFrames, LibPQ, CSV, SHA, MCMCChains, MCMCChainsStorage, HDF5

function push!(connection, uid, amount::Int, ts = Dates.now())
  execute(connection, "INSERT INTO data (timestamp, uid, amount) VALUES('$(ts)', '$(uid)', '$(amount)')")
end

function pull(connection)
  result = execute(connection, "SELECT * FROM data")
  return DataFrame(result)
end

function pull(connection, uid::String)
  result = execute(connection, "SELECT * FROM data WHERE uid = \$1", [uid])
  return DataFrame(result)
end

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

function uid(user::String)::String
  replace(user, r"[^0-9]" => s"")
end

function average(d::AbstractDataFrame)::Float64
  total = sum(d.amount)
  n_days = length(unique(Dates.format.(d.timestamp, "d.m.yyyy")))
  return total / n_days
end

function count(s::String)::Int
  length(split(s, r"🍺")) - 1
end

function enquote(s::String)
  return "<@" * s * ">"
end


function endofyear()
  return Date(year(today()), 12, 31)
end

function checksum(df::DataFrame)
  hash(df)
end

function checksum(f::String)
  isfile(f) || return UInt64(0)
  df = CSV.read(f, DataFrame)
  df.uid = string.(df.uid)
  checksum(df)
end

function save!(chain::Chains)
  h5open("data/mcmc-chains.h5", "w") do f
    write(f, chain)
  end
  return nothing
end

function save!(df::DataFrame, filename::String)
  CSV.write("data/$filename", df)
  return nothing
end
