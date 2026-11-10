import { availableParallelism } from "node:os";
import { defineConfig } from "vitest/config";

// src/**/*.test.ts: the pure libs (run by every host's vitest too — they travel with the vendored src/).
// test/**/*.test.tsx: the components in jsdom with a fake KanbanApi (this repo only; the deps are dev-only here).
export default defineConfig({
  test: {
    globals: true,
    environment: "jsdom",
    include: ["src/**/*.test.ts", "test/**/*.test.ts", "test/**/*.test.tsx"],
    setupFiles: ["test/setup.ts"],
    // every CPU this process may use, read at run time
    maxWorkers: availableParallelism(),
  },
});
