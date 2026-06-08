def translate(input_sentence, target_language, max_len=max_len):
    # Tokenisation de la phrase source
    input_sequence = sp.EncodeAsIds(input_sentence)
    input_sequence = pad_sequences([input_sequence], maxlen=max_len, padding='post')

    # Initialisation du décodeur avec le token de langue cible
    target_lang_id = LANGUAGE_TOKENS[target_language]
    decoder_input = np.zeros((1, max_len), dtype=int)
    decoder_input[0, 0] = target_lang_id

    # Traduction itérative
    for i in range(1, max_len):
        outputs = model.predict([input_sequence, decoder_input])
        translation_pred = outputs[0]
        predicted_id = np.argmax(translation_pred[0, i-1, :])
        if predicted_id == sp.PieceToId('</s>'):
            break
        decoder_input[0, i] = predicted_id

    # Conversion des IDs en texte
    translated_ids = decoder_input[0, 1:i]
    translated_text = sp.DecodeIds(translated_ids.tolist())
    return translated_text

# Exemple d'utilisation
input_sentence = "Bonjour, comment allez-vous ?"
target_language = 'en'  # Langue cible souhaitée
translated_text = translate(input_sentence, target_language)
print("Traduction :", translated_text)
