import torch
import torch.nn as nn
from torchvision import models, transforms
from PIL import Image

class FeatureExtractor:
    def __init__(self):
        print("🔄 Loading ResNet50 for Visual Embeddings...")
        # Load pre-trained ResNet50
        weights = models.ResNet50_Weights.DEFAULT
        self.model = models.resnet50(weights=weights)
        
        # Remove the final classification layer (The "FC" layer)
        # We want the raw features (2048 dimensions), not the class prediction
        self.model = nn.Sequential(*list(self.model.children())[:-1])
        
        self.model.eval() # Set to evaluation mode
        
        # Standard ImageNet normalization
        self.preprocess = transforms.Compose([
            transforms.Resize((224, 224)),
            transforms.ToTensor(),
            transforms.Normalize(mean=[0.485, 0.456, 0.406], 
                                 std=[0.229, 0.224, 0.225]),
        ])
        print("✅ ResNet50 Loaded.")

    def get_embedding(self, cv2_image):
        # Convert OpenCV (BGR) to PIL (RGB)
        img = Image.fromarray(cv2_image[:, :, ::-1])
        
        # Preprocess
        input_tensor = self.preprocess(img)
        input_batch = input_tensor.unsqueeze(0) # Create mini-batch

        # Inference
        with torch.no_grad():
            output = self.model(input_batch)
        
        # Flatten [1, 2048, 1, 1] -> [2048]
        return output.squeeze().numpy().tolist()