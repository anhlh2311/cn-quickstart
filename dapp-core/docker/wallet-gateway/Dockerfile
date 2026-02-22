FROM node:20-alpine

RUN npm install -g @canton-network/wallet-gateway-remote@0.18.0

EXPOSE 3030

# 1) Run migrations (create tables if missing)
# 2) Bootstrap (seed IDPs + networks — ignore if already seeded)
# 3) Start server
CMD ["sh", "-c", "wallet-gateway db up -c /app/config.json; wallet-gateway db bootstrap -c /app/config.json || true; wallet-gateway -c /app/config.json -f json"]
