.PHONY: up down test iex psql
up:    ; docker compose up -d db
down:  ; docker compose down
test:  ; docker compose run --rm -e MIX_ENV=test api mix test $(ARGS)
iex:   ; docker compose run --rm api iex -S mix
psql:  ; docker compose exec db psql -U postgres ticket_rush_dev
