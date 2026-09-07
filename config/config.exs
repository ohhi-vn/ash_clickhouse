import Config

# Ash 3.33+ requires this to count string length for `min_length`/`max_length`
# constraints. `:codepoints` matches how SQL data layers (including ClickHouse)
# count string length, so Elixir-side validation matches what is stored.
config :ash, default_string_length_count: :codepoints

if config_env() == :test do
  import_config "test.exs"
end
