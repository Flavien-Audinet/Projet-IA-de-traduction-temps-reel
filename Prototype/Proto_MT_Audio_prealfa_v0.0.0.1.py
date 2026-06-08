import sounddevice as sd
import numpy as np
import whisper
from googletrans import Translator
from gtts import gTTS
import pygame
from pydub import AudioSegment
import io
import sys

# Initialisation du modèle Whisper
try:
    model = whisper.load_model("base")
except Exception as e:
    print(f"Error loading Whisper model: {e}")
    sys.exit(1)

# Initialisation du traducteur
translator = Translator()

# Initialisation de Pygame pour la lecture audio
pygame.mixer.init()

# Paramètres d'enregistrement
fs = 44100  # Taux d'échantillonnage
duration = 10  # Durée de l'enregistrement en secondes

# Buffers pour l'enregistrement
audio_buffer = []

# Fonction pour traiter l'audio
def process_audio(indata, frames, time, status):
    if status:
        print(status, file=sys.stderr)
    audio_buffer.append(indata.copy())

# Fonction pour transcrire et traduire l'audio
def transcribe_and_translate(audio_data):
    try:
        # Convertir l'audio en format WAV avec pydub
        audio_data = np.concatenate(audio_data, axis=0)
        audio_segment = AudioSegment(
            data=audio_data.tobytes(),
            sample_width=audio_data.dtype.itemsize,
            frame_rate=fs,
            channels=1
        )
        audio_file = io.BytesIO()
        audio_segment.export(audio_file, format="wav")
        audio_file.seek(0)
        
        # Lire le fichier WAV et le convertir en tableau NumPy
        audio_segment = AudioSegment.from_wav(audio_file)
        audio_array = np.array(audio_segment.get_array_of_samples())
        
        # Assurer que le tableau NumPy est modifiable
        audio_array = np.copy(audio_array)
        
        # Transcription
        result = model.transcribe(audio_array)
        transcribed_text = result['text']
        
        # Traduction
        translated_text = translator.translate(transcribed_text, dest='fr').text
        print("Translated Text:", translated_text)
        
        return translated_text
    except Exception as e:
        print(f"Error in transcription and translation: {e}")
        return ""

# Fonction pour jouer le texte traduit
def play_translated_audio(text):
    try:
        tts = gTTS(text=text, lang='fr')
        audio_file = io.BytesIO()
        tts.write_to_fp(audio_file)
        audio_file.seek(0)
        
        # Lire le fichier audio
        pygame.mixer.music.load(audio_file)
        pygame.mixer.music.play()
        
        # Attendre la fin de la lecture
        while pygame.mixer.music.get_busy():
            pygame.time.Clock().tick(10)
    except Exception as e:
        print(f"Error playing translated audio: {e}")

# Enregistrement de l'audio en temps réel
try:
    with sd.InputStream(samplerate=fs, channels=1, callback=process_audio):
        print("Recording...")
        sd.sleep(duration * 1000)  # Enregistre pendant la durée spécifiée
except Exception as e:
    print(f"Error recording audio: {e}")
    sys.exit(1)

print("Processing audio...")
translated_text = transcribe_and_translate(audio_buffer)

print("Playing translated audio...")
play_translated_audio(translated_text)

print("Done.")

