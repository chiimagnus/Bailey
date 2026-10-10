import { createFileRoute } from '@tanstack/react-router'
import { HomePage } from '@/components/home-page'
import { homeCopy } from '@/lib/home-copy'
import { DEFAULT_LANGUAGE } from '@/lib/i18n'

/** English landing page. Other languages live at `/$lang`. */
export const Route = createFileRoute('/')({
  component: Home,
  head: () => {
    const copy = homeCopy(DEFAULT_LANGUAGE)
    return {
      meta: [
        { title: copy.title },
        { name: 'description', content: copy.description },
      ],
    }
  },
})

function Home() {
  return <HomePage lang={DEFAULT_LANGUAGE} />
}
