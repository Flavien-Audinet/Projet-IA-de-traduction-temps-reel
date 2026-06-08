from transformers import MarianMTModel, MarianTokenizer

# Modèle multilingue vers le français
model_name = 'Helsinki-NLP/opus-mt-mul-fr'

# Charger le tokenizer et le modèle pré-entraîné
tokenizer = MarianTokenizer.from_pretrained(model_name)
model = MarianMTModel.from_pretrained(model_name)

def traduire_vers_francais(texte):
    # Préparation du texte en entrée
    if isinstance(texte, str):
        texte = [texte]
    # Tokenisation
    inputs = tokenizer(texte, return_tensors='pt', padding=True)
    # Génération de la traduction
    with torch.no_grad():
        traductions = model.generate(**inputs)
    # Décodage des traductions
    texte_traduit = [tokenizer.decode(t, skip_special_tokens=True) for t in traductions]
    return texte_traduit[0]

# Exemple d'utilisation
texte_source = "Hello, how are you?"
texte_traduit = traduire_vers_francais(texte_source)
print("Texte source :", texte_source)
print("Texte traduit :", texte_traduit)

