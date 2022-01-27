using Baerbelbot, DotEnv, Turing, LibPQ, Gadfly

Gadfly.push_theme(:dark)

DotEnv.config()

Turing.setadbackend(:reversediff)
Turing.setrdcache(true)

const db = LibPQ.Connection("""
  host=$(ENV["DATABASE_HOST"])
  port=$(ENV["DATABASE_PORT"])
  user=$(ENV["DATABASE_USER"])
  password=$(ENV["DATABASE_PASSWORD"])
  dbname=$(ENV["DATABASE_NAME"])
""")

Baerbelbot.init(db)  # initial forecast
Baerbelbot.main(db)
