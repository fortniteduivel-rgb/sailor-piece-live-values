FROM ruby:3.3-slim

WORKDIR /app

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && gem install --no-document webrick

COPY . .

ENV PORT=10000
ENV BIND_ADDRESS=0.0.0.0

EXPOSE 10000

CMD ["ruby", "server.rb"]
