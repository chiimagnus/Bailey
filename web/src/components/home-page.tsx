import type { ReactNode } from 'react'
import { SiteLayout } from '@/components/site-layout'
import { DocsLink } from '@/components/site-links'
import { homeCopy, type Row } from '@/lib/home-copy'
import { GITHUB_URL } from '@/lib/links'

const BUTTON =
  'inline-flex items-center gap-2 rounded-[9px] border border-border bg-card px-4 py-[7px] text-foreground transition-colors hover:border-brand hover:bg-brand/8 hover:text-brand'

/** The landing page, rendered once per language from `homeCopy`. */
export function HomePage({ lang }: { lang: string }) {
  const copy = homeCopy(lang)

  return (
    <SiteLayout
      lang={lang}
      headerContent={
        <>
          <p className="text-foreground/70">
            {copy.taglineBefore}
            <span className="text-brand">{copy.taglineHighlight}</span>
            {copy.taglineAfter}
            <span
              aria-hidden
              className="ml-[5px] inline-block h-[1.05em] w-[7px] animate-caret rounded-[1px] bg-brand align-[-0.15em] motion-reduce:animate-none"
            />
          </p>
          <p className="mt-3.5 text-muted-foreground">
            {copy.intro}
            <br />
            {copy.introFree}
          </p>
        </>
      }
    >
      <section className="flex flex-col gap-3.5">
        <div className="flex flex-wrap items-center gap-2.5">
          <a href={lang === 'zh' ? '/zh/docs/installation' : '/docs/installation'} className={BUTTON}>
            <span className="i-mingcute-apple-fill size-4 shrink-0" />
            {copy.build}
          </a>
          <DocsLink lang={lang} className={BUTTON}>
            <span className="i-mingcute-book-2-fill size-4 shrink-0" />
            {copy.docs}
          </DocsLink>
          <a href={GITHUB_URL} target="_blank" rel="noreferrer" className={BUTTON}>
            <span className="i-mingcute-github-fill size-4 shrink-0" />
            GitHub
          </a>
        </div>
        <div className="flex flex-wrap items-center gap-2 text-[13px] text-muted-foreground">
          <Pill>macOS 15.6+</Pill>
          <Pill>{copy.pillFree}</Pill>
        </div>
      </section>

      <figure className="m-0 flex flex-col gap-2">
        <img
          src="/kero-screenshot.png"
          alt={copy.screenshotAlt}
          width={2286}
          height={1568}
          className="block w-full rounded-lg border border-border bg-card"
        />
        <figcaption className="text-[13px] text-muted-foreground">
          {copy.screenshotCaption}
        </figcaption>
      </figure>

      <section className="flex flex-col gap-3.5">
        <SectionHeading>{copy.featuresHeading}</SectionHeading>
        <div className="flex flex-col gap-7">
          {copy.features.map((section) => (
            <div key={section.group} className="flex flex-col gap-3">
              <h3 className="flex items-center gap-3 text-xs font-normal tracking-[0.04em] text-foreground/60 after:h-px after:flex-1 after:bg-border after:content-['']">
                {section.group}
              </h3>
              <ul className="grid list-none gap-2 p-0">
                {section.rows.map((row) => (
                  <DefinitionRow key={row.name} {...row} />
                ))}
              </ul>
            </div>
          ))}
        </div>
      </section>

      <section className="flex flex-col gap-3.5">
        <SectionHeading>{copy.shortcutsHeading}</SectionHeading>
        <ul className="grid list-none gap-2 p-0">
          {copy.shortcuts.map((row) => (
            <DefinitionRow key={row.name} {...row} />
          ))}
        </ul>
      </section>

      <section className="flex flex-col gap-3.5">
        <SectionHeading>{copy.faqHeading}</SectionHeading>
        <div className="flex flex-col gap-2">
          {copy.faq.map((item) => (
            <details key={item.q} className="group border-b border-border">
              <summary className="flex cursor-pointer list-none items-baseline gap-2.5 py-2 text-foreground transition-colors hover:text-brand [&::-webkit-details-marker]:hidden">
                <span
                  aria-hidden
                  className="flex-none text-muted-foreground before:content-['+'] group-open:before:content-['–']"
                />
                {item.q}
              </summary>
              <p className="mb-3 ml-5 text-muted-foreground">{item.a}</p>
            </details>
          ))}
        </div>
      </section>
    </SiteLayout>
  )
}

/* ------------------------------------------------------------------ */

function SectionHeading({ children }: { children: ReactNode }) {
  return (
    <h2 className="text-[13px] font-normal tracking-[0.04em] text-muted-foreground">
      {children}
    </h2>
  )
}

function Pill({ children }: { children: ReactNode }) {
  return (
    <span className="inline-flex items-center rounded-[6px] border border-border px-2 py-[3px]">
      {children}
    </span>
  )
}

/** A label/description pair — the page's one repeating unit. */
function DefinitionRow({ name, detail }: Row) {
  return (
    <li className="group grid grid-cols-[190px_1fr] items-baseline gap-4 max-[560px]:grid-cols-1 max-[560px]:gap-0.5">
      <span className="text-foreground transition-colors group-hover:text-brand">
        {name}
      </span>
      <span className="text-muted-foreground transition-colors group-hover:text-foreground">
        {detail}
      </span>
    </li>
  )
}
