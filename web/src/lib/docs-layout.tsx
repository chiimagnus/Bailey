import type { BaseLayoutProps } from 'fumadocs-ui/layouts/shared'
import { DEFAULT_LANGUAGE } from '@/lib/i18n'
import { GITHUB_URL } from '@/lib/links'

const NAV_LABELS = {
  en: { home: 'Home', build: 'Build locally' },
  zh: { home: '首页', build: '本地构建' },
} as const

/** Chrome shared by every docs page: the kero wordmark plus links back to the site. */
export function docsLayoutOptions(lang: string): BaseLayoutProps {
  const labels = NAV_LABELS[lang as keyof typeof NAV_LABELS] ?? NAV_LABELS.en
  const home = lang === DEFAULT_LANGUAGE ? '/' : `/${lang}`

  return {
    githubUrl: GITHUB_URL,
    // The site has no light mode, so a light/dark toggle would be a control
    // that does nothing.
    themeSwitch: { enabled: false },
    nav: {
      url: home,
      title: (
        <span className="inline-flex items-center gap-2">
          <img
            src="/kero-icon.png"
            alt=""
            width={100}
            height={100}
            className="size-5 rounded-[5px] border border-zinc-600"
          />
          <span className="font-mono font-bold tracking-[0.02em]">kero</span>
        </span>
      ),
    },
    links: [
      { text: labels.home, url: home, active: 'url' },
      {
        type: 'button', text: labels.build,
        url: lang === DEFAULT_LANGUAGE ? '/docs/installation' : `/${lang}/docs/installation`,
        active: 'url',
      },
    ],
  }
}
