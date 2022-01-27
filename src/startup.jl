include("db.jl")
include("utils.jl")
include("predict.jl")

Gadfly.push_theme(:dark)

function init()
  @info "Pulling new data from DB..."
  data = pull(db)
  save!(data, "data.csv")

  @info "Fitting forecast model..."
  chain, predictions = forecast(data)

  @info "Saving data..."
  save!(chain)
  save!(predictions, "predictions.csv")
  return nothing
end

init()
