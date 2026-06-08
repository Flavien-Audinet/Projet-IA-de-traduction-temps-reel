import tensorflow as tf
from tensorflow import keras
from keras.layers import Input, Embedding, Dense, LayerNormalization, Dropout
from keras.preprocessing.text import Tokenizer
from keras.preprocessing.sequence import pad_sequences
import numpy as np
import pickle

# Parameters
batch_size = 64
epochs = 20
embedding_dim = 256
num_heads = 8
ff_dim = 512
max_seq_length = 100
english_file = 'WikiMatrix.en-fr.txt.en'
french_file = 'WikiMatrix.en-fr.txt.fr'

# Load and preprocess data
def load_texts(file_paths):
    texts = []
    for file_path in file_paths:
        with open(file_path, 'r', encoding='utf-8') as f:
            texts.append([line.strip() for line in f.readlines()])
    return texts

english_texts, french_texts = load_texts([english_file, french_file])

# Tokenize texts
tokenizer_eng = Tokenizer(filters='', lower=False)
tokenizer_eng.fit_on_texts(english_texts)
tokenizer_fr = Tokenizer(filters='', lower=False)
tokenizer_fr.fit_on_texts(french_texts)

# Save tokenizers
with open('tokenizer_eng.pkl', 'wb') as f:
    pickle.dump(tokenizer_eng, f)
with open('tokenizer_fr.pkl', 'wb') as f:
    pickle.dump(tokenizer_fr, f)

# Convert texts to sequences
encoder_input_sequences = tokenizer_eng.texts_to_sequences(english_texts)
decoder_input_sequences = tokenizer_fr.texts_to_sequences(french_texts)

# Pad sequences
encoder_input_data = pad_sequences(encoder_input_sequences, maxlen=max_seq_length, padding='post')
decoder_input_data = pad_sequences(decoder_input_sequences, maxlen=max_seq_length, padding='post')

# Prepare decoder target data by shifting decoder input by one
decoder_target_data = np.concatenate(
    [decoder_input_data[:, 1:], np.zeros((decoder_input_data.shape[0], 1), dtype=int)],
    axis=1
)

# Create tf.data.Dataset
dataset = tf.data.Dataset.from_tensor_slices((
    {'encoder_inputs': encoder_input_data, 'decoder_inputs': decoder_input_data},
    decoder_target_data
))
dataset = dataset.shuffle(buffer_size=len(encoder_input_data))
dataset = dataset.batch(batch_size)
dataset = dataset.prefetch(tf.data.AUTOTUNE)

# Split into training and validation sets
validation_split = 0.1
validation_size = int(len(encoder_input_data) * validation_split)
train_dataset = dataset.skip(validation_size)
validation_dataset = dataset.take(validation_size)

# Transformer components
class TransformerBlock(keras.layers.Layer):
    def __init__(self, embed_dim, num_heads, ff_dim, rate=0.1):
        super().__init__()
        self.att = keras.layers.MultiHeadAttention(num_heads=num_heads, key_dim=embed_dim)
        self.ffn = keras.Sequential([
            Dense(ff_dim, activation='relu'),
            Dense(embed_dim),
        ])
        self.layernorm1 = LayerNormalization(epsilon=1e-6)
        self.layernorm2 = LayerNormalization(epsilon=1e-6)
        self.dropout1 = Dropout(rate)
        self.dropout2 = Dropout(rate)
    
    def call(self, inputs, training, mask=None):
        attn_output = self.att(inputs, inputs, attention_mask=mask)
        attn_output = self.dropout1(attn_output, training=training)
        out1 = self.layernorm1(inputs + attn_output)
        ffn_output = self.ffn(out1)
        ffn_output = self.dropout2(ffn_output, training=training)
        return self.layernorm2(out1 + ffn_output)

def positional_encoding(maxlen, embed_dim):
    pos = np.arange(maxlen)[:, np.newaxis]
    i = np.arange(embed_dim)[np.newaxis, :]
    angle_rates = 1 / np.power(10000, (2 * (i//2)) / np.float32(embed_dim))
    angle_rads = pos * angle_rates
    angle_rads[:, 0::2] = np.sin(angle_rads[:, 0::2])
    angle_rads[:, 1::2] = np.cos(angle_rads[:, 1::2])
    return tf.cast(angle_rads[np.newaxis, ...], dtype=tf.float32)

class TokenAndPositionEmbedding(keras.layers.Layer):
    def __init__(self, maxlen, vocab_size, embed_dim):
        super().__init__()
        self.token_emb = Embedding(input_dim=vocab_size, output_dim=embed_dim, mask_zero=True)
        self.pos_emb = Embedding(input_dim=maxlen, output_dim=embed_dim, weights=[positional_encoding(maxlen, embed_dim)], trainable=False)
    
    def call(self, x):
        maxlen = tf.shape(x)[-1]
        positions = tf.range(start=0, limit=maxlen, delta=1)
        positions = self.pos_emb(positions)
        x = self.token_emb(x)
        return x + positions

# Build the Transformer model
embed_dim = embedding_dim
ff_dim = ff_dim

# Encoder
encoder_inputs = Input(shape=(None,), name='encoder_inputs')
encoder_embedding = TokenAndPositionEmbedding(max_seq_length, len(tokenizer_eng.word_index) + 1, embed_dim)
encoder_x = encoder_embedding(encoder_inputs)
encoder_output = TransformerBlock(embed_dim, num_heads, ff_dim)(encoder_x)

# Decoder
decoder_inputs = Input(shape=(None,), name='decoder_inputs')
decoder_embedding = TokenAndPositionEmbedding(max_seq_length, len(tokenizer_fr.word_index) + 1, embed_dim)
decoder_x = decoder_embedding(decoder_inputs)
# Masked multi-head attention
look_ahead_mask = tf.linalg.band_part(tf.ones((max_seq_length, max_seq_length)), -1, 0)
decoder_block = TransformerBlock(embed_dim, num_heads, ff_dim)
decoder_output = decoder_block(decoder_x, mask=look_ahead_mask)

# Final output
decoder_dense = Dense(len(tokenizer_fr.word_index) + 1, activation='softmax')
outputs = decoder_dense(decoder_output)

# Define the model
model = Model([encoder_inputs, decoder_inputs], outputs)
model.compile(optimizer='adam', loss='sparse_categorical_crossentropy', metrics=['accuracy'])

# Add callbacks
checkpoint_filepath = 'model_checkpoint.h5'
checkpoint_callback = keras.callbacks.ModelCheckpoint(
    filepath=checkpoint_filepath,
    save_weights_only=True,
    save_best_only=True,
    monitor='val_loss',
    verbose=1
)

# Train the model
model.fit(
    train_dataset,
    validation_data=validation_dataset,
    epochs=epochs,
    callbacks=[checkpoint_callback]
)

# Save the final model
model.save('final_model.h5')
