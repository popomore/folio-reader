import { productCopy } from './locales/index.ts';
import type { Product } from './site-kit/types';

export const product = {
  id: 'folio',
  name: 'Folio',
  repository: 'https://github.com/popomore/folio-reader',
  guide: 'https://github.com/popomore/folio-reader#readme',
  release: {
    tag: 'v0.1.1.1794846141-a710e4b',
    url: 'https://github.com/popomore/folio-reader/releases/tag/v0.1.1.1794846141-a710e4b',
    download: 'https://github.com/popomore/folio-reader/releases/download/v0.1.1.1794846141-a710e4b/Folio-0.1.1-1794846141.ga710e4b-arm64.dmg',
  },
  hero: { src: '/images/preview.webp', width: 1360, height: 1160 },
  storyImage: { src: '/images/split.webp', width: 2260, height: 1520 },
  copy: productCopy,
} satisfies Product;
