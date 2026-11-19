import {createI18n} from "vue-i18n";

// Import only the fallback language files
import en from './public/assets/locale/en.json'

async function fetchLocaleJson(url) {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 3000);
    try {
        const response = await fetch(url, {signal: controller.signal});
        return response.ok ? await response.json() : null;
    } catch {
        return null;
    } finally {
        clearTimeout(timeout);
    }
}

export default async function() {
    let locale = 'en';
    const messages = { en };
    // The bundled English strings keep setup usable while the service starts.
    const selected = (await fetchLocaleJson('./api/configLocale'))?.locale;
    if (typeof selected === 'string' && selected !== 'en' && /^[a-z]{2,3}(?:_[A-Z]{2})?$/.test(selected)) {
        const dictionary = await fetchLocaleJson(`./assets/locale/${selected}.json`);
        if (dictionary && typeof dictionary === 'object' && !Array.isArray(dictionary)) {
            messages[selected] = dictionary;
            locale = selected;
        }
    }
    document.documentElement.lang = locale.replace('_', '-');
    return createI18n({locale, fallbackLocale: 'en', messages});
}
