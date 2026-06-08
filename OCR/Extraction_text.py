import cv2
import pytesseract
from PIL import Image

# Ouvrez la vidéo
cap = cv2.VideoCapture('output.avi', cv2.CAP_FFMPEG)

# Créez un fichier pour stocker le texte
with open('output.txt', 'w') as f:
    while True:
        ret, frame = cap.read()
        if not ret:
            break

        # Réduisez la taille de la vidéo
        frame = cv2.resize(frame, (640, 480))

        # Appliquez un filtre de pré-traitement
        frame = cv2.GaussianBlur(frame, (5, 5), 0)

        # Convertissez le frame en image
        image = Image.fromarray(frame)

        # Spécifiez la langue du texte
        text = pytesseract.image_to_string(image, lang='fra')

        # Écrivez le texte dans le fichier
        f.write(text + '\n')

# Fermez la vidéo
cap.release()