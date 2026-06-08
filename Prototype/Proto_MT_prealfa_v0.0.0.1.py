import pytesseract
from PIL import ImageGrab
import pyaudio
import wave
import whisper
import torch
from transformers import MBartForConditionalGeneration, MBart50Tokenizer
from google.cloud import texttospeech

# OCR - Capture d'écran et extraction du texte
def ocr_from_screen():
    screenshot = ImageGrab.grab()  # Capture l'écran
    text = pytesseract.image_to_string(screenshot)  # Extraction du texte avec Tesseract
    return text

# Capture Audio
def record_audio(output_filename="input_audio.wav", record_seconds=5):
    chunk = 1024
    sample_format = pyaudio.paInt16
    channels = 1
    fs = 44100
    p = pyaudio.PyAudio()

    print("Recording...")
    stream = p.open(format=sample_format, channels=channels,
                    rate=fs, frames_per_buffer=chunk, input=True)
    frames = []

    for _ in range(0, int(fs / chunk * record_seconds)):
        data = stream.read(chunk)
        frames.append(data)

    stream.stop_stream()
    stream.close()
    p.terminate()

    wf = wave.open(output_filename, 'wb')
    wf.setnchannels(channels)
    wf.setsampwidth(p.get_sample_size(sample_format))
    wf.setframerate(fs)
    wf.writeframes(b''.join(frames))
    wf.close()

    print("Recording finished.")
    return output_filename

# ASR - Transcription Audio
def transcribe_audio(filename):
    model = whisper.load_model("base")
    result = model.transcribe(filename)
    return result['text']

# Traduction avec MBART
def translate_text(text, source_lang="en", target_lang="fr"):
    tokenizer = MBart50Tokenizer.from_pretrained("facebook/mbart-large-50-many-to-many-mmt")
    model = MBartForConditionalGeneration.from_pretrained("facebook/mbart-large-50-many-to-many-mmt")

    tokenizer.src_lang = source_lang
    encoded_text = tokenizer(text, return_tensors="pt")
    generated_tokens = model.generate(**encoded_text, forced_bos_token_id=tokenizer.lang_code_to_id[target_lang])
    translated_text = tokenizer.batch_decode(generated_tokens, skip_special_tokens=True)[0]
    
    return translated_text

# Synthèse Vocale
def synthesize_speech(text, lang="fr", voice_name="fr-FR-Wavenet-A", output_filename="output_audio.wav"):
    client = texttospeech.TextToSpeechClient()

    synthesis_input = texttospeech.SynthesisInput(text=text)
    voice = texttospeech.VoiceSelectionParams(
        language_code=lang, name=voice_name
    )
    audio_config = texttospeech.AudioConfig(
        audio_encoding=texttospeech.AudioEncoding.LINEAR16
    )

    response = client.synthesize_speech(
        input=synthesis_input, voice=voice, audio_config=audio_config
    )

    with open(output_filename, "wb") as out:
        out.write(response.audio_content)
        print(f"Audio content written to file {output_filename}")

    return output_filename

# Exemple d'utilisation du prototype

# 1. OCR - Extraction du texte à partir de l'écran
text_from_screen = ocr_from_screen()
print(f"Extracted Text: {text_from_screen}")

# 2. Capture Audio et transcription
audio_filename = record_audio()
transcribed_text = transcribe_audio(audio_filename)
print(f"Transcribed Text: {transcribed_text}")

# 3. Traduction (Texte OCR et Audio Transcrit)
translated_text_from_screen = translate_text(text_from_screen, source_lang="en", target_lang="fr")
translated_text_from_audio = translate_text(transcribed_text, source_lang="en", target_lang="fr")
print(f"Translated Text from Screen: {translated_text_from_screen}")
print(f"Translated Text from Audio: {translated_text_from_audio}")

# 4. Synthèse Vocale - Imitation de la voix avec traduction
synthesized_audio = synthesize_speech(translated_text_from_audio, lang="fr", voice_name="fr-FR-Wavenet-A")

