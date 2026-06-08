import tensorflow as tf
from tensorflow import keras
from keras.layers import Input, Embedding, Dense, LayerNormalization, Dropout
from keras.models import Model
from keras.preprocessing.sequence import pad_sequences
import sentencepiece as spm
import numpy as np

# Charger le tokenizer SentencePiece entraîné sur un corpus multilingue
sp = spm.SentencePieceProcessor(model_file='spm.model')
vocab_size = sp.get_piece_size()

# Dictionnaire des codes de langue et des IDs correspondants dans le vocabulaire
LANGUAGE_TOKENS = {
    'fr': sp.PieceToId('<fr>'),
    'en': sp.PieceToId('<en>'),
    'zh': sp.PieceToId('<zh>'),
    # Ajoutez d'autres langues si nécessaire
}

# Paramètres du modèle
embedding_dim = 256
num_heads = 8
ff_dim = 512
max_len = 100

# Définition des entrées
encoder_inputs = Input(shape=(None,), name='encoder_inputs')
decoder_inputs = Input(shape=(None,), name='decoder_inputs')

# Embedding partagé
embedding_layer = Embedding(input_dim=vocab_size, output_dim=embedding_dim, mask_zero=True)

encoder_embeddings = embedding_layer(encoder_inputs)
decoder_embeddings = embedding_layer(decoder_inputs)

# Blocs Transformer simplifiés
def transformer_block(inputs):
    attn_output = keras.layers.MultiHeadAttention(num_heads=num_heads, key_dim=embedding_dim)(inputs, inputs)
    attn_output = Dropout(0.1)(attn_output)
    out1 = LayerNormalization(epsilon=1e-6)(inputs + attn_output)
    ffn_output = keras.Sequential([
        Dense(ff_dim, activation='relu'),
        Dense(embedding_dim),
    ])(out1)
    ffn_output = Dropout(0.1)(ffn_output)
    return LayerNormalization(epsilon=1e-6)(out1 + ffn_output)

# Encodeur
encoder_outputs = transformer_block(encoder_embeddings)

# Détecteur de langue (sur les sorties de l'encodeur)
language_detection = Dense(len(LANGUAGE_TOKENS), activation='softmax', name='language_detection')(encoder_outputs)

# Décodeur
decoder_outputs = transformer_block(decoder_embeddings)

# Couche finale de sortie
decoder_dense = Dense(vocab_size, activation='softmax', name='translation')
translation_outputs = decoder_dense(decoder_outputs)

# Modèle avec deux sorties : traduction et détection de langue
model = Model([encoder_inputs, decoder_inputs], [translation_outputs, language_detection])

# Compilation du modèle avec des pertes et des métriques pour chaque tâche
model.compile(optimizer='adam',
              loss={'translation': 'sparse_categorical_crossentropy', 'language_detection': 'sparse_categorical_crossentropy'},
              metrics={'translation': 'accuracy', 'language_detection': 'accuracy'})

# Préparation des données
def prepare_data(sources, targets, target_languages, max_len):
    # Tokenisation des sources
    encoder_input_sequences = [sp.EncodeAsIds(text) for text in sources]
    encoder_input_sequences = pad_sequences(encoder_input_sequences, maxlen=max_len, padding='post')

    # Tokenisation des cibles avec ajout du token de langue cible
    decoder_input_sequences = []
    decoder_target_sequences = []
    for idx, text in enumerate(targets):
        lang_token_id = LANGUAGE_TOKENS[target_languages[idx]]
        tokens = [lang_token_id] + sp.EncodeAsIds(text)
        decoder_input_sequences.append(tokens[:-1])
        decoder_target_sequences.append(tokens[1:])
    decoder_input_sequences = pad_sequences(decoder_input_sequences, maxlen=max_len, padding='post')
    decoder_target_sequences = pad_sequences(decoder_target_sequences, maxlen=max_len, padding='post')

    # Étiquettes pour la détection de langue (on utilise le même pour tous les tokens)
    language_labels = np.array([LANGUAGE_TOKENS[lang] for lang in target_languages])
    language_labels = np.tile(language_labels[:, np.newaxis], (1, max_len))  # Étendre pour chaque position

    return [encoder_input_sequences, decoder_input_sequences], [decoder_target_sequences, language_labels]

# Supposons que vous avez les listes suivantes :
# sources : phrases sources
# targets : phrases cibles
# target_languages : liste des langues cibles correspondantes

# Préparez les données
inputs, outputs = prepare_data(sources, targets, target_languages, max_len)

# Entraînement du modèle
model.fit(inputs, outputs, batch_size=64, epochs=10, validation_split=0.1)
