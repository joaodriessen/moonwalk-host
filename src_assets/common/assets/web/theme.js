// Define which themes are dark (for Bootstrap compatibility)
const darkThemes = new Set([
    'dark',
    'ember',
    'midnight',
    'moonlight',
    'nord',
    'slate',
])

function showActiveTheme(theme, buttons, focus) {
    const themeSwitcher = document.querySelector('#bd-theme')

    if (!themeSwitcher) {
        return
    }

    const themeSwitcherText = document.querySelector('#bd-theme-text')
    const activeThemeIcon = document.querySelector('.theme-icon-active svg')
    const btnToActive = buttons.find(button => button.dataset.bsThemeValue === theme)

    if (!btnToActive) {
        return
    }

    const btnIcon = btnToActive.querySelector('svg')

    if (!activeThemeIcon || !btnIcon) {
        return
    }

    buttons.forEach(element => {
        element.classList.remove('active')
        element.setAttribute('aria-pressed', 'false')
    })

    btnToActive.classList.add('active')
    btnToActive.setAttribute('aria-pressed', 'true')

    // Clone the SVG icon from the active button to the theme switcher
    const clonedIcon = btnIcon.cloneNode(true)
    activeThemeIcon.parentNode.replaceChild(clonedIcon, activeThemeIcon)

    const themeSwitcherLabel = `${themeSwitcherText.textContent} (${btnToActive.textContent.trim()})`
    themeSwitcher.setAttribute('aria-label', themeSwitcherLabel)

    if (focus) {
        themeSwitcher.focus()
    }
}

export function setupThemeToggleListener() {
    const buttons = Array.from(document.querySelectorAll('[data-bs-theme-value]'))
    const appearance = window.matchMedia('(prefers-color-scheme: dark)')
    let selection = 'auto'
    try {
        const saved = localStorage.getItem('theme')
        if (buttons.some(button => button.dataset.bsThemeValue === saved)) selection = saved
    } catch {
        // Browsers can block preference storage for this origin.
    }

    function applyTheme() {
        const theme = selection === 'auto' ? (appearance.matches ? 'dark' : 'light') : selection
        document.documentElement.dataset.theme = theme
        document.documentElement.dataset.bsTheme = darkThemes.has(theme) ? 'dark' : 'light'
    }

    for (const button of buttons) {
        button.addEventListener('click', () => {
            selection = button.dataset.bsThemeValue
            applyTheme()
            showActiveTheme(selection, buttons, true)
            try {
                localStorage.setItem('theme', selection)
            } catch {
                // The current page still uses the chosen appearance.
            }
        })
    }
    applyTheme()
    showActiveTheme(selection, buttons, false)
    appearance.addEventListener('change', applyTheme)
    return () => appearance.removeEventListener('change', applyTheme)
}
