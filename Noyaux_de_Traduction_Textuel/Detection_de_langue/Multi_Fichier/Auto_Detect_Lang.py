# script_pretraitement.py

from langdetect import detect
import re

# Dictionnaire des tokens de langue
LANGUAGE_TOKENS = {
    'fr': '<fr>',
    'en': '<en>',
    'zh-cn': '<zh>',
    # Ajoutez d'autres langues si nécessaire
}

def detect_language(text):
    try:
        return detect(text)
    except:
        return 'unknown'

def preprocess_text(text, target_language):
    # Segmentation en mots
    words = re.findall(r'\w+|\s+|[^\s\w]+', text)
    preprocessed_words = []
    for word in words:
        if word.strip() == '':
            preprocessed_words.append(word)
            continue
        lang = detect_language(word)
        lang_token = LANGUAGE_TOKENS.get(lang, '<unk>')
        preprocessed_words.append(f"{lang_token} {word}")
    # Ajout du token de langue cible au début
    target_lang_token = LANGUAGE_TOKENS.get(target_language, '<unk>')
    preprocessed_text = f"{target_lang_token} " + ''.join(preprocessed_words)
    return preprocessed_text.strip()
