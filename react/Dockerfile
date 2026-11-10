# Test image for the React port. Node only; the deps are installed INTO the bind mount (npm install, run in a
# throwaway container) so the lockfile and node_modules stay in sync:
#   docker build -t agents-kanban-react:dev react
#   docker run --rm -v "$PWD/react":/app -w /app node:22-slim npm install
#   docker run --rm -v "$PWD":/repo -w /repo/react agents-kanban-react:dev npm test
#   docker run --rm -v "$PWD":/repo -w /repo/react agents-kanban-react:dev npm run typecheck
#   docker run --rm -v "$PWD":/repo -w /repo/react agents-kanban-react:dev npm run lint      (eslint.config.js, 0 warnings)
FROM node:22-slim
WORKDIR /app
ENV CI=true
