import tensorflow as tf
from tensorflow import keras
from keras.models import Model
from keras.layers import Input, LSTM, Dense
import numpy as np
import json
from collections import defaultdict

# Fonction pour reconstruire le modèle
def build_model(latent_dim, num_encoder_tokens, num_decoder_tokens):
    # Encoder
    encoder_inputs = Input(shape=(None, num_encoder_tokens))
    encoder = LSTM(latent_dim, return_state=True)
    encoder_outputs, state_h, state_c = encoder(encoder_inputs)
    encoder_states = [state_h, state_c]

    # Decoder
    decoder_inputs = Input(shape=(None, num_decoder_tokens))
    decoder_lstm = LSTM(latent_dim, return_sequences=True, return_state=True)
    decoder_outputs, _, _ = decoder_lstm(decoder_inputs, initial_state=encoder_states)
    decoder_dense = Dense(num_decoder_tokens, activation='softmax')
    decoder_outputs = decoder_dense(decoder_outputs)

    model = Model([encoder_inputs, decoder_inputs], decoder_outputs)
    return model

# Charger les vocabulaires
with open('english_token_index.json') as f:
    english_token_index = json.load(f)
with open('french_token_index.json') as f:
    french_token_index = json.load(f)

reverse_french_token_index = {i: word for word, i in french_token_index.items()}
num_encoder_tokens = len(english_token_index)
num_decoder_tokens = len(french_token_index)
latent_dim = 256  # Assurez-vous que cela correspond au latent_dim utilisé lors de la formation

# Recréer le modèle
model = build_model(latent_dim, num_encoder_tokens, num_decoder_tokens)

# Charger les poids
model.load_weights('model_checkpoint.h5')

# Fonctions auxiliaires
def tokenize_text(text, token_index, max_len):
    tokens = text.split()
    token_indices = [token_index.get(token, 0) for token in tokens]
    return token_indices + [0] * (max_len - len(token_indices))  # Padding

def encode_text(text, token_index, max_len):
    token_indices = tokenize_text(text, token_index, max_len)
    return np.array([token_indices])

def decode_sequence(sequence, reverse_index_token):
    text = ' '.join([reverse_index_token.get(idx, '') for idx in sequence if idx > 0])
    return text

# Fonction de traduction
def translate_text(input_text):
    encoder_input_seq = encode_text(input_text, english_token_index, max_encoder_seq_length)
    
    # Encoder le texte
    encoder_output, state_h, state_c = model.layers[0].predict(encoder_input_seq)
    
    # Initialiser le texte du décodeur avec un token de début
    start_token = np.zeros((1, 1, num_decoder_tokens))
    start_token[0, 0, french_token_index.get('starttoken', 0)] = 1.
    
    decoded_tokens = []
    decoder_input_seq = start_token
    for _ in range(max_decoder_seq_length):
        output_tokens, h, c = model.layers[2].predict([decoder_input_seq] + [state_h, state_c])
        decoder_output_tokens = model.layers[3].predict(output_tokens)
        
        sampled_token_index = np.argmax(decoder_output_tokens[0, -1, :])
        sampled_token = reverse_french_token_index.get(sampled_token_index, '')
        if sampled_token == 'endtoken' or not sampled_token:
            break
        
        decoded_tokens.append(sampled_token)
        
        decoder_input_seq = np.zeros((1, 1, num_decoder_tokens))
        decoder_input_seq[0, 0, sampled_token_index] = 1.
        state_h, state_c = h, c
    
    return ' '.join(decoded_tokens)

# Tester la traduction avec une entrée manuelle
input_text = input("Entrez une phrase en anglais à traduire : ")
translated_text = translate_text(input_text)
print(f"Traduction en français : {translated_text}")

