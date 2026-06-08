import tensorflow as tf
from tensorflow import keras
from keras.models import Model
from keras.layers import Input, LSTM, Dense
from keras.callbacks import ModelCheckpoint
import numpy as np
from collections import defaultdict
import psutil
import time

# Fonction pour construire l'index des tokens
def build_token_index(texts):
    token_index = defaultdict(lambda: len(token_index))
    for text in texts:
        tokens = text.split()
        for token in tokens:
            _ = token_index[token]
    return dict(token_index)

# Fonction pour tokeniser le texte
def tokenize_text(text, token_index, max_len):
    tokens = text.split()
    token_indices = [token_index.get(token, 0) for token in tokens]
    return token_indices + [0] * (max_len - len(token_indices))  # Padding

# Générateur de batchs
def batch_generator(english_file, french_file, batch_size=64):
    with open(english_file, 'r', encoding='utf-8') as eng_f, open(french_file, 'r', encoding='utf-8') as fr_f:
        while True:
            batch_eng_texts = []
            batch_fr_texts = []
            for _ in range(batch_size):
                eng_line = eng_f.readline()
                fr_line = fr_f.readline()
                if not eng_line or not fr_line:
                    if batch_eng_texts:
                        yield batch_eng_texts, batch_fr_texts
                    return
                batch_eng_texts.append(eng_line.strip())
                batch_fr_texts.append(fr_line.strip())
            yield batch_eng_texts, batch_fr_texts

# Préparation des données
def preprocess_batch(batch_eng_texts, batch_fr_texts):
    encoder_input_data = np.zeros((len(batch_eng_texts), max_encoder_seq_length, num_encoder_tokens), dtype='float32')
    decoder_input_data = np.zeros((len(batch_fr_texts), max_decoder_seq_length, num_decoder_tokens), dtype='float32')
    decoder_output_data = np.zeros((len(batch_fr_texts), max_decoder_seq_length, num_decoder_tokens), dtype='float32')

    for i, (eng_text, fr_text) in enumerate(zip(batch_eng_texts, batch_fr_texts)):
        encoder_input_seq = tokenize_text(eng_text, english_token_index, max_encoder_seq_length)
        decoder_input_seq = tokenize_text(fr_text, french_token_index, max_decoder_seq_length)
        for t in range(len(encoder_input_seq)):
            encoder_input_data[i, t, encoder_input_seq[t]] = 1.
        for t in range(len(decoder_input_seq) - 1):
            decoder_input_data[i, t, decoder_input_seq[t]] = 1.
            decoder_output_data[i, t, decoder_input_seq[t + 1]] = 1.

    return encoder_input_data, decoder_input_data, decoder_output_data

# Suivi en temps réel des ressources
def monitor_resources():
    cpu_usage = psutil.cpu_percent(interval=1)
    ram_usage = psutil.virtual_memory().percent
    print(f"CPU Usage: {cpu_usage}%")
    print(f"RAM Usage: {ram_usage}%")
    # Monitoring GPU
    gpus = tf.config.list_physical_devices('GPU')
    if gpus:
        for gpu in gpus:
            device_info = tf.config.experimental.get_device_details(gpu)
            print(f"GPU Device Name: {device_info.get('device_name', 'Unknown')}")
            print(f"GPU Memory Limit: {device_info.get('memory_limit', 'Unknown')} MB")

# Compteur de FPS
class FPSCounter:
    def __init__(self):
        self.start_time = time.time()
        self.frames = 0

    def update(self):
        self.frames += 1
        elapsed_time = time.time() - self.start_time
        if elapsed_time > 1.0:  # Calcule les FPS toutes les secondes
            fps = self.frames / elapsed_time
            print(f"FPS: {fps:.2f}")
            self.start_time = time.time()
            self.frames = 0

# Paramètres
batch_size = 256
epochs = 100
latent_dim = 256
max_encoder_seq_length = 80  # Définir selon les besoins
max_decoder_seq_length = 100  # Définir selon les besoins
english_file = 'WikiMatrix.en-fr.txt.en'
french_file = 'WikiMatrix.en-fr.txt.fr'

# Construire les vocabulaires
sample_batch_size = 1000
sample_batch = next(batch_generator(english_file, french_file, sample_batch_size))
english_token_index = build_token_index(sample_batch[0])
french_token_index = build_token_index(sample_batch[1])
num_encoder_tokens = len(english_token_index)
num_decoder_tokens = len(french_token_index)

# Créer le modèle
encoder_inputs = Input(shape=(None, num_encoder_tokens))
encoder = LSTM(latent_dim, return_state=True)
encoder_outputs, state_h, state_c = encoder(encoder_inputs)
encoder_states = [state_h, state_c]

decoder_inputs = Input(shape=(None, num_decoder_tokens))
decoder_lstm = LSTM(latent_dim, return_sequences=True, return_state=True)
decoder_outputs, _, _ = decoder_lstm(decoder_inputs, initial_state=encoder_states)
decoder_dense = Dense(num_decoder_tokens, activation='softmax')
decoder_outputs = decoder_dense(decoder_outputs)

model = Model([encoder_inputs, decoder_inputs], decoder_outputs)
model.compile(optimizer='rmsprop', loss='categorical_crossentropy')

# Ajouter un Callback pour sauvegarder les checkpoints
checkpoint_filepath = 'model_checkpoint.h5'
checkpoint_callback = ModelCheckpoint(
    filepath=checkpoint_filepath,
    save_weights_only=True,
    save_best_only=False,
    save_freq='epoch',
    verbose=1
)

# Entraînement du modèle avec affichage du pourcentage complété et du FPS
total_batches = sum(1 for _ in open(english_file)) // batch_size
fps_counter = FPSCounter()

for epoch in range(epochs):
    print(f"Epoch {epoch + 1}/{epochs}")
    start_time = time.time()
    batch_count = 0
    for batch_eng_texts, batch_fr_texts in batch_generator(english_file, french_file, batch_size):
        batch_count += 1
        encoder_input_data, decoder_input_data, decoder_output_data = preprocess_batch(batch_eng_texts, batch_fr_texts)
        model.fit([encoder_input_data, decoder_input_data], decoder_output_data, batch_size=batch_size, epochs=1, verbose=1, callbacks=[checkpoint_callback])
        monitor_resources()
        fps_counter.update()  # Mise à jour du compteur de FPS
        percentage_complete = (batch_count / total_batches) * 100
        print(f"Epoch progress: {percentage_complete:.2f}%")
    end_time = time.time()
    epoch_duration = end_time - start_time
    print(f"Epoch {epoch + 1} duration: {epoch_duration:.2f} seconds")

# Sauvegarder le modèle final
model.save('final_model.h5')

