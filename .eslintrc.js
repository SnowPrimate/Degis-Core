module.exports = {
  env: {
    browser: true,
    es2021: true,
    node: true,
    mocha: true,
  },
  extends: [
    "eslint:recommended",
    // Vue "plugin:vue/essential",
    // React "plugin:react/recommended",
    "plugin:@typescript-eslint/recommended",
    "plugin:prettier/recommended",
    "plugin:node/recommended",
  ],
  parserOptions: {
    ecmaFeatures: {
      jsx: true,
    },
    ecmaVersion: "latest",
    sourceType: "module",
  },
  plugins: [
    // Vue "vue",
    // React "react",
    // Typescript "@typescript-eslint",
    "prettier",
  ],
  rules: {
    indent: ["error", 4],
    "linebreak-style": ["error", "auto"],
    quotes: ["error", "single"],
    semi: ["error", "always"],
    "comma-dangle": ["error", "always-multiline"],
    "node/no-unsupported-features/es-syntax": [
      "error",
      { ignores: ["modules"] },
    ],
    "prettier/prettier": [
      "error",
      {
        endOfLine: "auto",
      },
    ],
    camelcase: "warn",
    // Typescript "@typescript-eslint/camelcase": "warn",
    "prefer-const": ["error", { destructuring: "all" }],
    "no-var": "error",
  },
};
