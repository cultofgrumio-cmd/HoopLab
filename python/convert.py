from ultralytics import YOLO

def convert_to_onnx():
    print("Converting to optimized ONNX format for CPU...")
    model = YOLO("best.pt")
    
    # Move model to CPU
    model.to('cpu')
    
    # Export with CPU-specific optimizations:
    # - smaller input size
    # - no half precision (FP16)
    # - simplified architecture
    # - older opset for compatibility
    model.export(
        format="onnx",
        imgsz=320,  # Reduced size for faster CPU inference
        half=False,  # Use FP32 for CPU
        simplify=True,  # Simplify model architecture
        opset=12,  # Better compatibility
        optimize=False,  # Disable GPU optimizations
        dynamic=True,  # Dynamic batch size support
        device='cpu'  # Ensure CPU usage
    )
    print("CPU-optimized ONNX model exported.")

if __name__ == "__main__":
    convert_to_onnx()
