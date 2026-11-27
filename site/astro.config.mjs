import { defineConfig } from 'astro/config';

export default defineConfig({
  site: 'https://folio.chuo.me',
  output: 'static',
  trailingSlash: 'always',
  build: { inlineStylesheets: 'never' },
});
