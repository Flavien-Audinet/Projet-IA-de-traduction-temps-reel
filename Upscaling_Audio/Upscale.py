import pyaudio
import numpy as np
import tensorflow as tf
from waveunet import WaveUNet  # Assurez-vous que Wave-U-Net est dans votre PYTHONPATH
import librosa

# Paramètres audio
RATE = 16000  # Fréquence d'échantillonnage
CHUNK = 1024  # Taille du buffer
CHANNELS = 1  # Mono

# Initialiser PyAudio
p = pyaudio.PyAudio()

# Charger un modèle pré-entraîné Wave-U-Net
model = WaveUNet()
model.load_weights("path_to_trained_model_weights.h5")  # Chemin vers les poids du modèle

# Fonction pour traiter un segment audio avec Wave-U-Net
def process_audio(audio_data):
    # Reshape en format attendu par le modèle Wave-U-Net
    audio_data = np.reshape(audio_data, (1, len(audio_data), CHANNELS))

    # Appliquer le modèle pour améliorer la qualité du son
    processed_audio = model.predict(audio_data)

    # Reshape pour la lecture en temps réel
    processed_audio = np.squeeze(processed_audio)

    return processed_audio

# Fonction callback pour le traitement en temps réel
def callback(in_data, frame_count, time_info, status):
    # Convertir le flux audio en numpy array
    audio_data = np.frombuffer(in_data, dtype=np.float32)

    # Appliquer le traitement avec Wave-U-Net
    processed_audio = process_audio(audio_data)

    # Reconvertir en bytes pour renvoyer à PyAudio
    out_data = processed_audio.astype(np.float32).tobytes()

    return (out_data, pyaudio.paContinue)

# Ouvrir un stream audio
stream = p.open(format=pyaudio.paFloat32,
                channels=CHANNELS,
                rate=RATE,
                input=True,
                output=True,
                frames_per_buffer=CHUNK,
                stream_callback=callback)

print("Traitement audio en temps réel démarré...")

# Démarrer le flux audio
stream.start_stream()

# Laisser tourner le script jusqu'à ce que l'utilisateur l'arrête
try:
    while stream.is_active():
        pass
except KeyboardInterrupt:
    print("Arrêt du traitement audio en temps réel.")

# Fermer le flux
stream.stop_stream()
stream.close()
p.terminate()
