// ESLint for the React port: typescript-eslint's type-checked recommended rules + the React hooks
// rules, over every source and test file. No file of ours is ignored and no rule is switched off; a finding is fixed.
//   docker run --rm -v "$PWD":/app -w /app node:22-slim npm run lint
import js from "@eslint/js";
import tseslint from "typescript-eslint";
import reactHooks from "eslint-plugin-react-hooks";

export default tseslint.config(
  { ignores: ["node_modules/"] },
  // an eslint-disable comment has no effect and is itself reported: a finding is fixed, never silenced
  { linterOptions: { noInlineConfig: true, reportUnusedDisableDirectives: "error" } },
  js.configs.recommended,
  tseslint.configs.recommendedTypeChecked,
  {
    languageOptions: {
      parserOptions: { projectService: true, tsconfigRootDir: import.meta.dirname },
    },
  },
  {
    files: ["eslint.config.js"],
    extends: [tseslint.configs.disableTypeChecked],
  },
  {
    files: ["**/*.{ts,tsx}"],
    plugins: { "react-hooks": reactHooks },
    rules: reactHooks.configs.recommended.rules,
  },
);
