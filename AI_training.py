import tensorflow as tf
from tensorflow import keras
from keras.models import Model
from keras.layers import Input, LSTM, Dense
import numpy as np
import librosa
from datasets import load_dataset
from collections import defaultdict

# Fonction pour créer un vocabulaire et mapper les tokens à des indices
def build_token_index(texts):
    token_index = defaultdict(lambda: len(token_index))
    for text in texts:
        tokens = text.split()
        for token in tokens:
            _ = token_index[token]
    return token_index

# Fonction pour convertir le texte en indices de token
def tokenize_text(text, token_index):
    tokens = text.split()
    return [token_index[token] for token in tokens]

# Fonction pour convertir l'audio
def convert_audio(audio):
    audio_array = audio['array']
    return audio_array

# Fonction pour prétraiter chaque exemple
def preprocess_example(example, token_index):
    try:
        audio_data = convert_audio(example['audio'])
        text_indices = tokenize_text(example['text'], token_index)
        return audio_data, text_indices[:-1], text_indices[1:]
    except Exception as e:
        print(f"Error processing {example['id']}: {e}")
        return None

# Fonction pour remplir les séquences
def pad_sequences(sequences, max_len, dtype='float32', padding='post'):
    """Pad each sequence to the same length."""
    num_samples = len(sequences)
    sample_shape = np.asarray(sequences[0]).shape[1:] if sequences else ()
    padded_sequences = np.zeros((num_samples, max_len) + sample_shape, dtype=dtype)
    for i, seq in enumerate(sequences):
        if len(seq) > max_len:
            padded_sequences[i] = seq[:max_len]
        else:
            padded_sequences[i, :len(seq)] = seq
    return padded_sequences

# Définir les dimensions
batch_size = 64
epochs = 100
latent_dim = 256
num_encoder_tokens = 1000
num_decoder_tokens = 2000
max_encoder_seq_length = 8000  # Définir la longueur maximale des séquences d'encodeur
max_decoder_seq_length = 100  # Définir la longueur maximale des séquences de décodeur

# Charger le dataset
print("Loading dataset...")
dataset = load_dataset("facebook/multilingual_librispeech", "german", split="train", streaming=True, trust_remote_code=True)

# Construire le vocabulaire
texts = [example['text'] for example in dataset]
token_index = build_token_index(texts)

# Définir les entrées et sorties
encoder_inputs = Input(shape=(None, num_encoder_tokens))
encoder = LSTM(latent_dim, return_state=True)
encoder_outputs, state_h, state_c = encoder(encoder_inputs)
encoder_states = [state_h, state_c]

decoder_inputs = Input(shape=(None, num_decoder_tokens))
decoder_lstm = LSTM(latent_dim, return_sequences=True, return_state=True)
decoder_outputs, _, _ = decoder_lstm(decoder_inputs, initial_state=encoder_states)
decoder_dense = Dense(num_decoder_tokens, activation='softmax')
decoder_outputs = decoder_dense(decoder_outputs)

# Créer les modèles
encoder_model = Model(encoder_inputs, encoder_states)
decoder_model = Model([decoder_inputs] + encoder_states, decoder_outputs)

# Compiler les modèles
encoder_model.compile(optimizer='rmsprop', loss='categorical_crossentropy')
decoder_model.compile(optimizer='rmsprop', loss='categorical_crossentropy')

# Préparer les données pour un seul batch
def prepare_batch(dataset_iter, batch_size, max_encoder_seq_length, max_decoder_seq_length, token_index):
    encoder_input_data = []
    decoder_input_data = []
    decoder_output_data = []
    
    for _ in range(batch_size):
        example = next(dataset_iter, None)
        if example is None:
            break
        
        result = preprocess_example(example, token_index)
        if result is not None:
            audio_data, decoder_input, decoder_output = result
            encoder_input_data.append(audio_data)
            decoder_input_data.append(decoder_input)
            decoder_output_data.append(decoder_output)
    
    encoder_input_data = pad_sequences(encoder_input_data, max_encoder_seq_length)
    decoder_input_data = pad_sequences(decoder_input_data, max_decoder_seq_length, dtype='int32')
    decoder_output_data = pad_sequences(decoder_output_data, max_decoder_seq_length, dtype='int32')
    
    return encoder_input_data, decoder_input_data, decoder_output_data

# Entraîner les modèles
print("Training the models...")
dataset_iter = iter(dataset)
for epoch in range(epochs):
    while True:
        encoder_input_batch, decoder_input_batch, decoder_output_batch = prepare_batch(dataset_iter, batch_size, max_encoder_seq_length, max_decoder_seq_length, token_index)
        
        if len(encoder_input_batch) == 0:
            break
        
        # Entraîner le modèle d'encodeur
        encoder_model.fit(encoder_input_batch, encoder_states, epochs=1, batch_size=batch_size, verbose=0)
        
        # Entraîner le modèle de décodeur
        decoder_model.fit([decoder_input_batch] + encoder_states, decoder_output_batch, epochs=1, batch_size=batch_size, verbose=0)

# Définir les indices des tokens
target_token_index = {'\t': 0}  # Définir les indices des tokens pour les tokens cibles
reverse_target_char_index = {0: '\t'}  # Définir les indices inverses des tokens pour les tokens cibles

# Fonction de décodage
def decode_sequence(input_seq):
    states_value = encoder_model.predict(input_seq)
    target_seq = np.zeros((1, 1, num_decoder_tokens))
    target_seq[0, 0, target_token_index['\t']] = 1.
    decoded_sentence = ''
    stop_condition = False
    while not stop_condition:
        output_tokens, h, c = decoder_model.predict([target_seq] + states_value)
        sampled_token_index = np.argmax(output_tokens[0, -1, :])
        sampled_char = reverse_target_char_index[sampled_token_index]
        decoded_sentence += sampled_char
        if (sampled_char == '\n' or len(decoded_sentence) > max_decoder_seq_length):
            stop_condition = True
        target_seq = np.zeros((1, 1, num_decoder_tokens))
        target_seq[0, 0, sampled_token_index] = 1.
        states_value = [h, c]
    return decoded_sentence

# Utiliser la fonction de décodage
dataset_iter = iter(dataset)
input_seq, _, _ = preprocess_example(next(dataset_iter), token_index)
input_seq = pad_sequences([input_seq], max_encoder_seq_length)
decoded_sentence = decode_sequence(np.array([input_seq]))
print(decoded_sentence)
