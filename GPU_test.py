import tensorflow as tf

# Vérifier si le GPU est détecté
print("Num GPUs Available: ", len(tf.config.experimental.list_physical_devices('GPU')))

