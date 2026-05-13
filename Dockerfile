FROM elixir:1.17-otp-27-alpine

RUN apk add --no-cache build-base git openssl ca-certificates
WORKDIR /app
ENV MIX_ENV=prod

COPY mix.exs mix.lock* ./
RUN mix local.hex --force && mix local.rebar --force && mix deps.get --only prod

COPY config ./config
COPY lib ./lib
COPY priv ./priv
RUN mix compile

EXPOSE 4000
CMD ["mix", "run", "--no-halt"]
