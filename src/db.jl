using DotEnv, LibPQ

DotEnv.config()

const db = LibPQ.Connection("""
  host=$(ENV["DATABASE_HOST"])
  port=$(ENV["DATABASE_PORT"])
  user=$(ENV["DATABASE_USER"])
  password=$(ENV["DATABASE_PASSWORD"])
  dbname=$(ENV["DATABASE_NAME"])
""")
