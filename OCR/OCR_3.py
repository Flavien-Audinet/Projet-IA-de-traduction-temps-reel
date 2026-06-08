import pytesseract
from PIL import Image

# Ouvrez l'image
image = Image.open('image.jpg')

# Utilisez Tesseract pour extraire le texte
text = pytesseract.image_to_string(image)

# Écrivez le texte dans un fichier
with open('output.txt', 'w') as f:
    f.write(text)
