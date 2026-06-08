from script_pretraitement import preprocess_text

def translate(input_sentence, target_language, max_len=max_len):
    # Prétraitement du texte
    preprocessed_text = preprocess_text(input_sentence, target_language)
    # Tokenisation
    input_sequence = sp.EncodeAsIds(preprocessed_text)
    input_sequence = pad_sequences([input_sequence], maxlen=max_len, padding='post')

    # Prédiction
    output = model.predict(input_sequence)
    predicted_ids = np.argmax(output[0], axis=-1)

    # Conversion des IDs en texte
    translated_ids = predicted_ids
    translated_text = sp.DecodeIds(translated_ids.tolist())
    return translated_text

# Exemple d'utilisation
input_sentence = "Bonjour, this is a test. 你好！"
target_language = 'en'
translated_text = translate(input_sentence, target_language)
print("Traduction :", translated_text)
