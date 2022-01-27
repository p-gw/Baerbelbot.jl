function init(db)
  @info "Pulling new data from DB..."
  data = pull(db)
  save!(data, "data.csv")

  @info "Fitting forecast model..."
  chain, predictions = forecast(data)

  @info "Saving data..."
  save!(chain)
  save!(predictions, "predictions.csv")

  @info "Plotting predictions..."
  predictions.username = predictions.uid
  p = plot_forecast(predictions, chain)
  p |> PNG("data/precompile_plot.png", 15cm, 10cm, dpi = 250)
  return nothing
end
