from ultralytics import YOLO

# Load the PyTorch model
model = YOLO('best.pt')

# Export to ONNX format
print("Converting to ONNX format...")
model.export(format='onnx', simplify=True)  # This will create best.onnx
print("Conversion complete! Check for best.onnx in the current directory.")
