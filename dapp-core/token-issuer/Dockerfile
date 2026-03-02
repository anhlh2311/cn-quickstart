FROM node:20-alpine AS build

WORKDIR /app

COPY package.json yarn.lock* ./
RUN corepack enable && yarn install

COPY tsconfig.json ./
COPY src/ ./src/

RUN yarn build

# Production stage
FROM node:20-alpine

WORKDIR /app

COPY --from=build /app/dist ./dist
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/package.json ./package.json

EXPOSE 3004

CMD ["node", "dist/index.js"]
