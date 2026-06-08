import cv2
import pytesseract
import numpy as np

# Définir le chemin vers l'exécutable Tesseract OCR
pytesseract.pytesseract.tesseract_cmd = 'C:\\Program Files\\Tesseract-OCR\\tesseract.exe'

# Ouvrir la capture d'écran
cap = cv2.VideoCapture(0)

while True:
    ret, frame = cap.read()
    if frame is None:
        break  # or handle the error somehow
    # ... rest of the code ...
    
    # Lire une frame de l'écran
    ret, frame = cap.read()
    
    # Convertir la frame en gris pour améliorer la reconnaissance de texte
    gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
    
    # Appliquer un seuil pour améliorer la qualité de l'image
    ret, thresh = cv2.threshold(gray, 0, 255, cv2.THRESH_BINARY_INV + cv2.THRESH_OTSU)
    
    # Extraire le texte de l'image
    text = pytesseract.image_to_string(thresh, lang='fra', config='--psm 11')
    
    # Afficher le texte extrait
    print(text)
    
    # Afficher la frame avec le texte extrait
    cv2.imshow('Screen', frame)
    
    # Attendre une touche pour quitter
    if cv2.waitKey(1) & 0xFF == ord('q'):
        break

# Fermer la capture d'écran
cap.release()
cv2.destroyAllWindows()