import pyautogui
import cv2
import numpy as np

# Définir le codec de la vidéo
fourcc = cv2.VideoWriter_fourcc(*'XVID')

# Définir les dimensions de la vidéo
screen_width, screen_height = pyautogui.size()

# Ouvrir la capture d'écran
out = cv2.VideoWriter("output.avi", fourcc, 30.0, (screen_width, screen_height))

while True:
    # Capturer l'écran
    img = pyautogui.screenshot()
    
    # Convertir l'image en format OpenCV
    frame = np.array(img)
    frame = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
    
    # Écrire la frame dans la vidéo
    out.write(frame)
    
    # Attendre une touche pour quitter
    if cv2.waitKey(1) & 0xFF == ord('q'):
        break

# Fermer la capture d'écran
out.release()
cv2.destroyAllWindows()