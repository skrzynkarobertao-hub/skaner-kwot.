import 'dart:io';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:permission_handler/permission_handler.dart';

List<CameraDescription> cameras = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Permission.camera.request();
  try {
    cameras = await availableCameras();
  } on CameraException catch (e) {
    debugPrint('Błąd kamery: $e');
  }
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Skaner Kwot PLN',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: const ScannerScreen(),
    );
  }
}

// Model pojedynczej wykrytej lub dodanej liczby
class DetectedNumber {
  String rawText;
  int valueInGrosze; // Usunięto 'final', aby umożliwić ręczną edycję
  final Rect boundingBox;
  bool isSelected;
  bool isEdited; // Flaga informująca, czy kwota była poprawiana ręcznie

  DetectedNumber({
    required this.rawText,
    required this.valueInGrosze,
    required this.boundingBox,
    this.isSelected = true,
    this.isEdited = false,
  });

  // Formatowanie wartości pojedynczej liczby (np. "9 123,23")
  String get formattedPLN {
    int zlote = valueInGrosze ~/ 100;
    int grosze = valueInGrosze % 100;
    String zloteStr = zlote.toString().replaceAllMapped(
      RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
      (Match m) => '${m[1]} ',
    );
    return '$zloteStr,${grosze.toString().padLeft(2, '0')}';
  }
}

class ScannerScreen extends StatefulWidget {
  const ScannerScreen({super.key});

  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen> {
  CameraController? _controller;
  final TextRecognizer _textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);
  
  XFile? _capturedImage;
  Size? _imageSize;
  List<DetectedNumber> _detectedNumbers = [];
  bool _isBusy = false;

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    if (cameras.isEmpty) return;
    _controller = CameraController(
      cameras[0],
      ResolutionPreset.high,
      enableAudio: false,
    );
    await _controller!.initialize();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller?.dispose();
    _textRecognizer.close();
    super.dispose();
  }

  // Funkcja robiąca zdjęcie i uruchamiająca analizę OCR
  Future<void> _scanPage() async {
    if (_controller == null || !_controller!.value.isInitialized || _isBusy) return;

    setState(() => _isBusy = true);

    try {
      final XFile image = await _controller!.takePicture();
      final InputImage inputImage = InputImage.fromFilePath(image.path);
      
      final decodedImage = await decodeImageFromList(await File(image.path).readAsBytes());
      _imageSize = Size(decodedImage.width.toDouble(), decodedImage.height.toDouble());

      final RecognizedText recognizedText = await _textRecognizer.processImage(inputImage);
      _extractNumbers(recognizedText);

      setState(() {
        _capturedImage = image;
      });
    } catch (e) {
      debugPrint("Błąd podczas skanowania: $e");
    } finally {
      setState(() => _isBusy = false);
    }
  }

  // Wyciąganie kwot z tekstu za pomocą wyrażeń regularnych
  void _extractNumbers(RecognizedText recognizedText) {
    List<DetectedNumber> results = [];

    final RegExp regExp = RegExp(
      r'(?<!\d)(\d{1,3}(?:[ \t]\d{3})+|\d+)(?:[.,](\d{1,2}))?(?!\d)',
      caseSensitive: false,
    );

    for (TextBlock block in recognizedText.blocks) {
      for (TextLine line in block.lines) {
        final matches = regExp.allMatches(line.text);
        
        for (final match in matches) {
          String fullMatch = match.group(0)!.trim();
          
          if (!fullMatch.contains(',') && !fullMatch.contains('.') && fullMatch.length < 2) {
            continue;
          }

          int? grosze = _parseToGrosze(fullMatch);
          if (grosze != null && grosze > 0) {
            Rect lineBox = line.boundingBox;
            double charWidth = lineBox.width / line.text.length;
            double left = lineBox.left + (match.start * charWidth);
            double right = lineBox.left + (match.end * charWidth);
            
            Rect numberBox = Rect.fromLTRB(left, lineBox.top, right, lineBox.bottom);

            results.add(DetectedNumber(
              rawText: fullMatch,
              valueInGrosze: grosze,
              boundingBox: numberBox,
              isSelected: true,
            ));
          }
        }
      }
    }

    _detectedNumbers = results;
  }

  // Dokładna konwersja tekstu (np. "9 123,23") na grosze (912323)
  int? _parseToGrosze(String text) {
    String cleaned = text.replaceAll(' ', '').replaceAll('\t', '');
    cleaned = cleaned.replaceAll(',', '.');

    List<String> parts = cleaned.split('.');
    if (parts.length > 2) return null;

    int? zlote = int.tryParse(parts[0]);
    if (zlote == null) return null;

    int grosze = 0;
    if (parts.length == 2) {
      String groszeStr = parts[1];
      if (groszeStr.length == 1) {
        groszeStr += '0';
      } else if (groszeStr.length > 2) {
        groszeStr = groszeStr.substring(0, 2);
      }
      grosze = int.tryParse(groszeStr) ?? 0;
    }

    return (zlote * 100) + grosze;
  }

  // Okienko do ręcznej edycji istniejącej kwoty (po przytrzymaniu ramki)
  Future<void> _showEditDialog(DetectedNumber number) async {
    int zlote = number.valueInGrosze ~/ 100;
    int grosze = number.valueInGrosze % 100;
    String initialText = '$zlote,${grosze.toString().padLeft(2, '0')}';

    final TextEditingController textController = TextEditingController(text: initialText);
    String? errorText;

    await showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Korekta kwoty'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Odczyt z aparatu: "${number.rawText}"',
                    style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: textController,
                    autofocus: true,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      labelText: 'Wpisz poprawną kwotę (PLN)',
                      hintText: 'np. 9123,23',
                      border: const OutlineInputBorder(),
                      errorText: errorText,
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () => textController.clear(),
                      ),
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('ANULUJ'),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.teal,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () {
                    final int? newGrosze = _parseToGrosze(textController.text);
                    if (newGrosze != null && newGrosze >= 0) {
                      setState(() {
                        number.valueInGrosze = newGrosze;
                        number.isEdited = true;
                        number.isSelected = true; // Automatycznie włącz po korekcie
                      });
                      Navigator.of(context).pop();
                    } else {
                      setDialogState(() {
                        errorText = 'Nieprawidłowy format (np. 123,45)';
                      });
                    }
                  },
                  child: const Text('ZAPISZ'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // Okienko do ręcznego dodania zupełnie nowej kwoty, której aparat nie zauważył
  Future<void> _showAddManualNumberDialog() async {
    final TextEditingController textController = TextEditingController();
    String? errorText;

    await showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Dodaj brakującą kwotę'),
              content: TextField(
                controller: textController,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: 'Kwota w PLN',
                  hintText: 'np. 450,00',
                  border: const OutlineInputBorder(),
                  errorText: errorText,
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('ANULUJ'),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.teal,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () {
                    final int? newGrosze = _parseToGrosze(textController.text);
                    if (newGrosze != null && newGrosze > 0) {
                      setState(() {
                        _detectedNumbers.add(DetectedNumber(
                          rawText: 'Dodano ręcznie',
                          valueInGrosze: newGrosze,
                          boundingBox: Rect.zero, // Brak ramki na zdjęciu
                          isSelected: true,
                          isEdited: true,
                        ));
                      });
                      Navigator.of(context).pop();
                    } else {
                      setDialogState(() {
                        errorText = 'Wpisz poprawną kwotę większą od 0';
                      });
                    }
                  },
                  child: const Text('DODAJ DO SUMY'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _resetScan() {
    setState(() {
      _capturedImage = null;
      _detectedNumbers.clear();
    });
  }

  String _calculateTotalSum() {
    int totalGrosze = _detectedNumbers
        .where((n) => n.isSelected)
        .fold(0, (sum, item) => sum + item.valueInGrosze);

    int zlote = totalGrosze ~/ 100;
    int grosze = totalGrosze % 100;

    String zloteStr = zlote.toString().replaceAllMapped(
      RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
      (Match m) => '${m[1]} ',
    );

    return '$zloteStr,${grosze.toString().padLeft(2, '0')} PLN';
  }

  @override
  Widget build(BuildContext context) {
    if (_controller == null || !_controller!.value.isInitialized) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    int selectedCount = _detectedNumbers.where((n) => n.isSelected).length;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Skaner Kwot PLN'),
        backgroundColor: Colors.teal.shade800,
        foregroundColor: Colors.white,
        actions: [
          if (_capturedImage != null) ...[
            IconButton(
              icon: const Icon(Icons.add_circle_outline),
              tooltip: 'Dopisz brakującą kwotę ręcznie',
              onPressed: _showAddManualNumberDialog,
            ),
            IconButton(
              icon: const Icon(Icons.select_all),
              tooltip: 'Zaznacz / Odznacz wszystkie',
              onPressed: () {
                bool anyUnselected = _detectedNumbers.any((n) => !n.isSelected);
                setState(() {
                  for (var n in _detectedNumbers) {
                    n.isSelected = anyUnselected;
                  }
                });
              },
            ),
          ],
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (_capturedImage == null)
                  CameraPreview(_controller!)
                else
                  _buildInteractiveImageOverlay(),

                if (_isBusy)
                  Container(
                    color: Colors.black54,
                    child: const Center(
                      child: CircularProgressIndicator(color: Colors.white),
                    ),
                  ),
              ],
            ),
          ),

          Container(
            padding: const EdgeInsets.all(16.0),
            decoration: BoxDecoration(
              color: Colors.grey.shade900,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            ),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_capturedImage != null) ...[
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Zaznaczono: $selectedCount z ${_detectedNumbers.length}',
                          style: const TextStyle(color: Colors.white70, fontSize: 13),
                        ),
                        const Text(
                          'Dotknij: wł/wył • Przytrzymaj: edytuj',
                          style: TextStyle(color: Colors.amberAccent, fontSize: 12),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'SUMA:',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          _calculateTotalSum(),
                          style: const TextStyle(
                            color: Colors.greenAccent,
                            fontSize: 28,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                  ],

                  SizedBox(
                    width: double.infinity,
                    height: 54,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _capturedImage == null ? Colors.teal : Colors.orange.shade800,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      icon: Icon(_capturedImage == null ? Icons.camera_alt : Icons.refresh),
                      label: Text(
                        _capturedImage == null ? 'ZESKANUJ KARTKĘ Z KWOTAMI' : 'SKANUJ KOLEJNĄ KARTKĘ',
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      onPressed: _capturedImage == null ? _scanPage : _resetScan,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInteractiveImageOverlay() {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (_imageSize == null) return const SizedBox();

        final double scaleX = constraints.maxWidth / _imageSize!.width;
        final double scaleY = constraints.maxHeight / _imageSize!.height;

        return Stack(
          fit: StackFit.expand,
          children: [
            Image.file(
              File(_capturedImage!.path),
              fit: BoxFit.fill,
            ),
            // Rysowanie ramek tylko dla liczb wykrytych na zdjęciu (boundingBox != Rect.zero)
            ..._detectedNumbers.where((n) => n.boundingBox != Rect.zero).map((number) {
              final rect = number.boundingBox;
              
              // Kolor ramki: Niebieski (edytowana i zaznaczona), Zielony (zaznaczona), Czerwony (odznaczona)
              final Color activeColor = number.isEdited ? Colors.lightBlueAccent : Colors.greenAccent;
              final Color activeBgColor = number.isEdited ? Colors.blue : Colors.green;

              return Positioned(
                left: (rect.left * scaleX) - 6,
                top: (rect.top * scaleY) - 6,
                width: (rect.width * scaleX) + 12,
                height: (rect.height * scaleY) + 12,
                child: GestureDetector(
                  onTap: () {
                    setState(() {
                      number.isSelected = !number.isSelected;
                    });
                  },
                  onLongPress: () => _showEditDialog(number),
                  child: Container(
                    decoration: BoxDecoration(
                      color: number.isSelected
                          ? activeBgColor.withOpacity(0.35)
                          : Colors.red.withOpacity(0.25),
                      border: Border.all(
                        color: number.isSelected ? activeColor : Colors.redAccent,
                        width: 2.5,
                      ),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        // Etykieta z nową kwotą wyświetlana nad ramką po ręcznej edycji
                        if (number.isEdited)
                          Positioned(
                            left: 0,
                            top: -20,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.blue.shade900,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                number.formattedPLN,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),
                        // Ikona w prawym górnym rogu ramki
                        Positioned(
                          right: -8,
                          top: -8,
                          child: CircleAvatar(
                            radius: 10,
                            backgroundColor: number.isSelected ? activeBgColor : Colors.red,
                            child: Icon(
                              number.isSelected
                                  ? (number.isEdited ? Icons.edit : Icons.check)
                                  : Icons.close,
                              size: 13,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }),
          ],
        );
      },
    );
  }
}
