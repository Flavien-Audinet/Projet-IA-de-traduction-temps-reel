import soundcard as sc
import numpy as np
import tensorflow as tf
import threading
from waveunet import WaveUNet  # Assurez-vous que Wave-U-Net est dans votre PYTHONPATH

# Paramètres audio
RATE = 48000  # Fréquence d'échantillonnage commune pour la qualité audio
CHUNK = 2048  # Taille du buffer, plus grand pour moins de latence de traitement
CHANNELS = 1  # Audio en mono

# Obtenir les périphériques par défaut (haut-parleur et loopback audio)
speaker = sc.default_speaker()
mic = sc.get_microphone(sc.default_microphone().name, include_loopback=True)

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

# Fonction pour la gestion du traitement audio asynchrone
def audio_processing_thread(audio_buffer, player):
    # Traiter chaque chunk dans un thread séparé
    processed_audio = process_audio(audio_buffer)
    player.play(processed_audio)

def main():
    print("Traitement audio en temps réel démarré...")

    # Démarrer la capture et le traitement en temps réel
    with mic.recorder(samplerate=RATE, channels=CHANNELS) as rec, \
         speaker.player(samplerate=RATE, channels=CHANNELS) as player:
        
        while True:
            # Capturer l'audio interne du système
            audio_data = rec.record(numframes=CHUNK)
            
            # Lancer le traitement audio dans un thread séparé pour éviter le blocage
            threading.Thread(target=audio_processing_thread, args=(audio_data, player)).start()

if __name__ == "__main__":
    main()
