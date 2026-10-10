import { DocsLink, HomeLink } from '@/components/site-links'
import { homeCopy } from '@/lib/home-copy'
import { DEFAULT_LANGUAGE, i18n } from '@/lib/i18n'
import { GITHUB_URL } from '@/lib/links'

const LINK = 'text-foreground transition-colors hover:text-brand'

export function SiteFooter({ lang = DEFAULT_LANGUAGE }: { lang?: string }) {
  const copy = homeCopy(lang)
  const others = i18n.languages.filter((code) => code !== lang)

  return (
    <footer className="text-[13px] text-muted-foreground">
      Kero · GPLv3 ·{' '}
      <a href={GITHUB_URL} target="_blank" rel="noreferrer" className={LINK}>
        GitHub
      </a>{' '}
      ·{' '}
      <DocsLink lang={lang} className={LINK}>
        {copy.footerDocs}
      </DocsLink>
      {others.map((code) => (
        <span key={code}>
          {' '}
          ·{' '}
          <HomeLink lang={code} className={LINK}>
            {homeCopy(code).languageName}
          </HomeLink>
        </span>
      ))}
    </footer>
  )
}
