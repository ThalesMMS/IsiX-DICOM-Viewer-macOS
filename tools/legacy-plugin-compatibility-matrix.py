#!/usr/bin/env python3
"""Compatibility matrix of legacy Horos/OsiriX plugins against the porting kit.

Runs the static inventory of tools/inventory-plugin-api.py over a collection
of legacy plugin sources (such as horosplugins) and, for every plugin, says:

- its band (simple, medium, complex) or that it is out;
- every legacy call, ivar, class, notification, header, library or platform
  feature it relies on that the porting kit and the plugin API v1 do not
  cover yet, with its name, its area and the porting stage that covers it;
- whether it depends on OpenGL or QuickTime/QTKit, which put it out, with the
  file and line of each use;
- whether it is out because the maintainer listed it as redundant with the
  application, an example, a test, specific to one site or of a dead
  platform, or because its function is planned to become part of the
  application, which also rules out converting it (EPIC_LIST below: data,
  not a judgement of this tool);
- whether its licence allows publishing a ported version: every source file
  must declare a permissive licence (MIT, BSD, Apache, ISC, zlib) and no
  copyleft one; GPL, LGPL or no licence is not enough.

Covered means declared. The porting kit compiles inside the plugin and gives
the legacy names to the legacy source through `@compatibility_alias`; a legacy
call is covered when a public Objective-C header of the kit (--kit-headers,
by default the IsiXLegacyBridge folder at the root of this repository when it
exists) declares that selector, ivar, property, class, notification, constant,
C function or header file, on the aliased class or on a class of the same
name. A header is covered when the kit has it at the path the plugin imports
it by (`<OsiriXAPI/PluginFilter.h>` through the kit's `Include` folders,
`"PluginFilter.h"` by name): a header of the legacy SDK the kit does not have
is missing, with the file and line of each import, since the plugin would not
compile. A plugin type is covered when the plugin API v1 sources (--plugin-kit,
by default IsiXPluginKit/Sources) declare the command placement it maps to.
Libraries the plugin must bring and Objective-C runtime use cannot be
declared in a header and stay listed until a port proves them. A Core Data
entity of the legacy database is covered when the kit offers its class
(DicomStudy for Study...): the kit's context evaluates fetches of it over the
plugin API. A class looked up by name (NSClassFromString, objc_getClass) is
covered when the kit's headers divert the lookup (`#define
NSClassFromString(...)`) and the kit has the class; with the divert, every
dynamic item the kit does not cover carries the reason: what the plugin gets
instead (nil and a message, never the application's class) or the stage that
deals with it. The converter's items (deprecated alerts, sheets, nib loading, file paths,
NSCalendarDate, garbage collection, Carbon, former SDK and architectures) are
covered by the converter when its report (--converter-report, written by
tools/port-legacy-plugin.py --collection ... --report) leaves nothing of that
kind in the plugin; what it leaves is listed with its file and line.

Each portable plugin ends in a final state (FINAL below, data): ported and
verified, ported without a full check, or out for what it lacks, named. The
coverage is the ported over the portable. With --ported-projects, the
collection of converted plugins kept outside this repository (one project per
folder, Porting/source.json naming the folder of the collection), the matrix
names each port's project and how many files its hand fixes changed, and
lists a ported plugin without a project.

Stages are named here (core, database, viewer, network, libraries, dynamic,
converter); --stage-issue STAGE=LABEL adds the label of the work item that
covers each stage to the report.

    python3 tools/legacy-plugin-compatibility-matrix.py \\
        --api-headers PATH/Horos.framework/Headers --macos-sdk "$(xcrun --show-sdk-path)" \\
        --collection PATH/horosplugins --markdown out.md --json out.json

Exit status 2 when the collection, the legacy SDK headers or a folder given
as an option are missing.
Nothing in the inputs is built, loaded or executed.
"""
import argparse
import importlib.util
import json
import os
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MISSING_INPUT = 2


def load_inventory():
    spec = importlib.util.spec_from_file_location("inventory_plugin_api", ROOT / "tools/inventory-plugin-api.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


inv = load_inventory()

# ---------------------------------------------------------------- data: maintainer decisions

PLANNED = "incorporação prevista"

# Plugins the maintainer put out because they add nothing to IsiX: they are
# neither ported nor counted in the coverage. Names are the folder names of
# the collection; the reason is the maintainer's, not this tool's.
EPIC_LIST = {
    "redundante": ["CalciumScore", "T2 Fit Map", "CMIR_T2_Fit_Map", "ROI Enhancement II", "OpenGL",
                   "Cobb Angle", "GantryTiltCorrection", "Orthogonal Reslice", "Resample Data",
                   "Create DICOMDIR", "jp2 plugin", "_obsolete/AutoClean", "contextualDictionary"],
    "exemplo": ["HelloWorld", "DB Test", "OSIDemoPlugin", "ITKPlugin", "XML-RPC-Plugin",
                "ExtraDatabaseColumnsSample", "AuditTrailDemo", "Create ROIs", "Invert - WindowController",
                "Duplicate", "DefaultDefaults"],
    "teste": ["JPEGCompressionTests"],
    "específico de uma instalação": ["UpdateDICOMNode", "WindowAnchoredAnnotations"],
    "plataforma morta": ["SafariPlugin"],
    "não é plugin": ["log", "SpotlightImporter"],
    # Functions the application will take in natively: these plugins are never converted.
    PLANNED: ["CloseThisStudy", "Invert Data", "Normalize", "T2 Ratio Map", "Reduce Series", "Fill the gaps",
              "PointsToLine", "ExportROIs", "JPEG to DICOM", "PDF to DICOM", "VoxelVolume", "Zombies",
              "KeyObjectSelection", "T1 Fit Map", "Worklists", "SeriesSameOrientation", "Ninety Degrees",
              # Despite its name it uses no Core Image: same code and function as Invert Data.
              "coreImageFilters"],
}
EPIC_REASON = {name: reason for reason, names in EPIC_LIST.items() for name in names}

# In scope although IsiX already does part of what they do.
PARTIAL = ["PetSpectFusion", "Align", "Volume Calculator", "PrintingLayout", "DiscPublishing", "Fusion Angio-CT tool"]

# Platform uses the maintainer accepted dropping in the port, so they do not
# put the plugin out: {plugin: {platform: what the port removes}}.
PORT_DROPS = {
    "DiscPublishing": {"QuickTime/QTKit": "a chamada que só inicializa o QTKit ([QTMovie movie]) e os seus imports"},
}

# The final state of each portable plugin: ported and verified (built for arm64
# and x86_64, loaded in the application and seen doing its main function on
# synthetic data), ported without a full check (with the reason), or left out
# for what it lacks (named). The proofs of the kit's stages are built from
# horosplugins by their own tests; every port is kept, as the converter wrote
# it plus its hand fixes, in the private collection of converted plugins
# (--ported-projects), which tests/test-isix-legacy-ported-plugins.py builds.
VERIFIED = "portado e verificado"
UNCHECKED = "portado sem checagem completa"
LACKING = "fora: falta"
_CORE = "prova do núcleo do kit (tests/test-isix-legacy-bridge.py)"
FINAL = {
    "Cardiac Tagging MRI": (VERIFIED, _CORE + ": a série inteira, num viewer novo"),
    "ROIRotation": (VERIFIED, _CORE + ": diálogo do nib, ROI girada"),
    "ROICorrectDisplayTextualData": (VERIFIED, _CORE + ": texto de todas as ROIs de todos os viewers"),
    "Vertebra": (VERIFIED, _CORE + ": a série copiada num viewer novo"),
    "NMSegmentation": (VERIFIED, "com o próprio ITK (tests/test-isix-legacy-itk-plugin.py): semente pelo clique, "
                                 "ROIs de pincel"),
    "32BitFloatDICOMExport": (VERIFIED, "banco do kit (tests/test-isix-legacy-database.py): a imagem em DICOM de 32 bits"),
    "VolumeGenerator": (VERIFIED, "banco do kit (tests/test-isix-legacy-database.py): volume gravado com DCMObject"),
    "Volume Calculator": (VERIFIED, "acesso por nome e eventos do viewer (tests/test-isix-legacy-dynamic-access.py, "
                                    "tests/test-isix-legacy-viewer-events.py)"),
    "CardiacStatistics": (VERIFIED, "eventos do viewer e janela própria (tests/test-isix-legacy-viewer-events.py)"),
    "Exec": (VERIFIED, "notificações do banco (tests/test-isix-legacy-network.py)"),
    "XploreReports": (VERIFIED, "notificações do banco (tests/test-isix-legacy-network.py)"),
    "SSH": (VERIFIED, "rede do kit (tests/test-isix-legacy-network.py); módulo SSH (o produto antigo se chamava JPEGtoDICOM)"),
    "BullsEye": (VERIFIED, "janela própria; Save DICOM grava o diagrama em RGB no estudo do viewer"),
    "Coronary": (VERIFIED, "cópia de BullsEye com o mesmo produto: módulo Coronary; correção à mão de uma variável com o "
                           "nome da sua classe"),
    "grid": (VERIFIED, "grade em todas as imagens e a imagem exportada em DICOM; correções à mão: AppController.h e a "
                       "chave MenuTitles que o conversor renomeia"),
    "SpineCounter": (VERIFIED, "tipo da ROI trocado e exportações de comprimentos e tipos; sem equivalente: os atalhos "
                               "nos menus do app e saveROI:; correções à mão nas categorias do app"),
    "Clustering": (VERIFIED, "dois IsiX trocam as imagens importadas pelo canal TCP do plugin; correção à mão do "
                             "endereço fora da rede do HUG"),
    "_obsolete/Casimage": (VERIFIED, "dados do paciente na área de transferência; o cliente do Casimage (4D Client) "
                                     "não existe mais"),
    "DMGS": (VERIFIED, "DMG dos estudos selecionados; sem DICOMDIR, porque o app não traz dcmmkdir; correções à mão: "
                       "categoria do app e pasta de saída"),
    "Fusion Angio-CT tool": (LACKING, "a função: o filterImage do plugin é vazio e a subtração CT-angio estava no código "
                                      "do próprio OsiriX"),
    "MATLAB": (LACKING, "o MATLAB Engine (engine.h, libeng, libmx) de uma instalação do MATLAB, e o alvo \"MATLAB "
                        "Plugin\" no conversor, que escolhe o alvo \"Unsupported\""),
    "PetSpectFusion": (LACKING, "fusão de viewers (blendWithViewer:blendingType:, setRegisteredViewer:), zoom "
                                "(scaleValue), CLUT e atributos PET/SUV do DCMPix; capacidades grandes da API v1"),
    "DiscPublishing": (LACKING, "utilitários N2 do app (NSThread+N2, NSFileManager+N2, N2Shell...), "
                                "DCMAbstractSyntaxUID, DicomCompressor, painel de preferências de plugin e o Weasis do "
                                "app: 72 itens do núcleo e 49 do banco"),
    "Ejection Fraction": (LACKING, "as classes de layout e passos do app (N2Steps, N2StepsView, N2ColumnLayout, "
                                   "N2CellDescriptor, N2Resizer...), N2UserDefaults e categorias de NSWindow"),
    "HipArthroplastyTemplating": (LACKING, "ROIs de camada (layerImage, groupID, generateEncodedLayerImage), N2Steps, "
                                           "N2Image, zoom e deslocamento do DCMView (origin) e arrastar para o viewer"),
    "HSS": (LACKING, "ThreadsManager, ThreadModalForWindowController, JSON.h, categorias N2 (NSData, NSString, NSXMLNode, "
                     "NSTextView), DicomCompressor e o outline do banco; e uma conta no serviço HSS"),
    "Reporter": (LACKING, "a captura do viewer como desenhado, -[ViewerController generateReport:] do app, ROIs guardadas "
                          "no banco (SRAnnotation, roiForImage:inArray:), painel de preferências e barra do viewer"),
    "DicomUnEnhancer": (LACKING, "DCMTK próprio com dcmimgle (a receita tem só dcmdata), utilitários N2 (NSThread+N2, "
                                 "ThreadModalForWindowController), apagar do banco e o dcm2nii de terceiros"),
}
PORTED = {name for name, (state, _) in FINAL.items() if state in (VERIFIED, UNCHECKED)}

# ---------------------------------------------------------------- data: stages

STAGES = ["core", "database", "viewer", "network", "libraries", "dynamic", "converter", "none"]
STAGE_TITLES = {
    "core": "núcleo (PluginFilter, ViewerController, DCMPix, ROI)",
    "database": "banco (estudos, séries, imagens, importação, DICOM derivado)",
    "viewer": "viewer, desenho, eventos e janelas",
    "network": "rede, integração e notificações",
    "libraries": "bibliotecas próprias",
    "dynamic": "acesso dinâmico",
    "converter": "conversor",
    "none": "sem etapa",
}

# Ordered: the first rule whose class pattern (and selector pattern, when
# given) matches names the stage of a legacy class or call.
STAGE_RULES = [
    (r"PluginFilter", r"^(handleEvent|toolbar|drawObjects|PLUGIN|duplicateCurrent2DViewerWindow|"
                      r"viewerControllersList)", "viewer"),
    (r"PluginFilter", r"(?i)report|^processFiles", "database"),
    (r"ViewerController", r"^(start|end)WaitWindow", "core"),
    (r"ViewerController", r"^(newWindow|ActivateBlending|blending|blendedWindow|setFusion|fusion|"
                          r"propagateSettings|syncro|.*Sync|duplicateCurrent2DViewerWindow|replaceSeries|"
                          r"openVR|.*MPR|.*VR|.*3D|.*CLUT|.*Opacity|.*[Tt]oolbar|windowWillClose|"
                          r"checkEverythingLoaded|.*[Ww]indow)", "viewer"),
    (r"ViewerController", None, "core"),
    # The viewer's image view: drawing, events, view geometry and sync belong to
    # the viewer stage; the current image, window level and ROIs to the core.
    (r"DCMView", r"(?i)draw|mouse|key|GL|display|blend|sync|zoom|scale|origin|rotation|flip|cursor|"
                 r"annotation|textual|menu|subview|frame|window|movie|fusion", "viewer"),
    (r"DCMView", None, "core"),
    (r"PreferencesWindowController|PreferencePane.*|.*PreferencePanePref|ToolbarPanel.*|ToolBarNSWindow|"
     r"ThumbnailsListPanel", None, "viewer"),
    (r"ThreadsManager|Wait.*", None, "core"),
    # DCM is the umbrella header of the legacy DICOM object framework (DCMObject and its kin).
    (r"DCM|DCMObject|DCMAttribute.*|DCMSequenceAttribute|DCMTransferSyntax|DCMCalendarDate|DCMDataContainer|"
     r"DCMTag.*|DCMCharacterSet|DCMValueRepresentation|DCMLimitedObject|DicomFile.*", None, "database"),
    (r"AYDicomPrint.*", None, "network"),
    (r"ITK.*|VTK.*|vtk.*", None, "libraries"),
]
AREA_STAGE = {"viewer": "viewer", "series-image-pixels": "core", "roi": "core", "database": "database",
              "menus-tools": "core", "export": "database", "network": "network", "other": "core"}

# Core Data entities of the legacy database and the kit class of each.
KIT_ENTITIES = {"Study": "DicomStudy", "Series": "DicomSeries", "Image": "DicomImage", "Album": "DicomAlbum"}

# Classes the kit is expected to offer, preferred when a call is ambiguous.
PREFERRED_CLASSES = ["ViewerController", "DCMPix", "ROI", "DCMView", "PluginFilter", "BrowserController",
                     "DicomStudy", "DicomSeries", "DicomImage", "DicomDatabase", "DICOMExport", "MyPoint"]

# Plugin types: the v1 command placement each one maps to (None: v1 has no
# such placement) and the stage that brings it.
PLUGIN_TYPES = {
    "imageFilter": ("IsiXCommand.Placement.imageFilters", "core"),
    "roiTool": ("IsiXCommand.Placement.roiTools", "core"),
    "Database": ("IsiXCommand.Placement.database", "core"),
    "database": ("IsiXCommand.Placement.database", "core"),
    "other": ("IsiXCommand.Placement.other", "core"),
    "Other": ("IsiXCommand.Placement.other", "core"),
    "fusionFilter": (None, "viewer"),
    "FileFormat": (None, "none"),
}

# Platform features found by the inventory: the stage that deals with each
# one. Absent: still in the macOS SDK, nothing to port. OpenGL and
# QuickTime/QTKit are not here: they put the plugin out.
PLATFORM_STAGES = {
    "garbage-collection": "converter",
    "legacy-alert/sheet": "converter",
    "deprecated-nib-loading": "converter",
    "deprecated-file-api": "converter",
    "NSCalendarDate": "converter",
    "Carbon": "converter",
    "legacy-sdk/arch": "converter",
    "objc_msgSend-cast": "dynamic",
    "Python/MATLAB bridge": "none",
}
DYNAMIC_FEATURES = {"objc runtime", "NSInvocation", "dlopen/dlsym"}
# Why a dynamic item stays missing once the kit diverts lookups by name: what
# the ported plugin gets instead. Keyed by item kind or feature.
DYNAMIC_REASONS = {
    "class": "o desvio do kit devolve nil e registra a mensagem, nunca a classe do app; sem equivalente no kit",
    "selector": "num objeto do kit, seletor sem equivalente devolve nil e registra a mensagem",
    "key": "chave de uma classe do app que o kit não tem; num objeto do kit, chave sem equivalente devolve nil e "
           "registra a mensagem",
    "objc runtime": "runtime sobre classes obtidas por nome: o desvio entrega as do kit, nunca as do app; trocar "
                    "métodos do app (itens de toolbar) fica sem equivalente",
    "NSInvocation": "invocação montada pelo plugin: num objeto do kit, seletor sem equivalente devolve nil e "
                    "registra a mensagem",
    "objc_msgSend-cast": "num objeto do kit, seletor sem equivalente devolve nil e registra a mensagem",
    "dlopen/dlsym": "biblioteca nativa carregada pelo próprio plugin: etapa das bibliotecas, não do desvio",
}
LIBRARY_STAGES = {"MATLAB": "none"}  # every other third-party library: "libraries"

# Uses that make a plugin depend on OpenGL or on QuickTime/QTKit. GLString
# and StringTexture are the host's OpenGL text textures.
OUT_PLATFORMS = [
    ("OpenGL", re.compile(r"<OpenGL/|<GLUT/|\bNSOpenGL\w+|\bCGL[A-Z]\w*|\bglu?[A-Z]\w*\s*\(|\bGL_[A-Z0-9_]+\b|"
                          r"\bGL(?:uint|int|float|double|enum|boolean|sizei|ubyte)\b|\bGLString\b|"
                          r"\bStringTexture\b")),
    ("QuickTime/QTKit", re.compile(r"<QTKit/|<QuickTime/|\bQTMovie\w*|\bQTTime\w*|\bQTMakeTime\w*|\bQTKit\b|"
                                   r"\bQTCapture\w+|\bQTDataReference\b|\bMovies\.h\b|\bEnterMovies\b")),
]

PERMISSIVE = [("MIT", r"\bMIT License\b|Permission is hereby granted, free of charge"),
              ("BSD", r"Redistribution and use in source and binary forms|\bBSD[- ]style\b|\bBSD [Ll]icen[cs]e\b"),
              ("Apache", r"Apache License"),
              ("ISC", r"\bISC License\b"),
              ("zlib", r"\bzlib License\b|This software is provided 'as-is'")]
COPYLEFT = [("LGPL", r"(?i)GNU\s+(Lesser|Library)\s+General\s+Public|\bLGPL"),
            ("GPL", r"GNU\s+General\s+Public\s+License|\bGNU\s*-?\s*GPL\b|\bGPL\b")]
# Vendored folders a port does not ship: copies of the legacy SDK, which the
# kit replaces, and build products.
NOT_SHIPPED = re.compile(r"(?i)(osirix|horos)[^/]*(headers|\.framework)$|(^|/)osirix$|(^|/)build$|derived ?data$")

LIMITS = [
    "Herda os limites do inventário (`tools/inventory-plugin-api.py`): leitura estática e textual, receptores "
    "tipados só por declaração, Swift sem tipos; `*` marca chamada atribuída por nome ou ambígua.",
    "Coberto = declarado num header Objective-C público do kit (seletor, ivar, propriedade, classe por nome "
    "ou `@compatibility_alias`, notificação, constante, função, arquivo de header) ou, para o tipo de plugin, "
    "o lugar de comando declarado no fonte do IsiXPluginKit. Declaração não prova comportamento.",
    "Header do SDK antigo importado pelo plugin: coberto quando o kit o tem no caminho do import "
    "(`<OsiriXAPI/PluginFilter.h>` pelas pastas `Include` do kit, `\"PluginFilter.h\"` pelo nome, sem "
    "distinguir maiúsculas, como nos volumes em que os plugins são compilados); sem ele o plugin não "
    "compila, e a falta sai com arquivo e linha de cada import.",
    "Bibliotecas próprias e runtime Objective-C não se declaram num header: ficam como falta até um port "
    "comprová-las. Uma entidade de Core Data (Study, Series, Image, Album) conta como coberta quando o kit "
    "oferece a classe dela: o contexto do kit avalia as buscas sobre a API v1.",
    "Etapa do conversor: um item está coberto quando o relatório de `tools/port-legacy-plugin.py` "
    "(`--converter-report`) não deixa nada daquele tipo no plugin; sem o relatório, fica em falta. O que o "
    "conversor deixa sai com arquivo e linha na seção do conversor. Reescrito não prova comportamento: o "
    "funcionamento é verificado pelos ports.",
    "Notificações por texto que não são nomes do SDK não são atribuídas ao host; contam como acesso dinâmico "
    "no inventário.",
    "Acesso dinâmico: `NSClassFromString`/`objc_getClass` de um nome antigo fica coberto quando o kit desvia a "
    "busca por nome (`#define NSClassFromString(...)` num header do kit) e tem a classe; o que fica em falta "
    "leva o motivo (o que o plugin recebe no lugar, ou a etapa que o trata). Coberto não prova comportamento: "
    "o desvio é verificado pelo teste do kit e pelos ports.",
    "OpenGL e QuickTime/QTKit: uso no código (tipos, funções, classes, imports), com arquivo e linha; um "
    "import sem uso aparece como nota e não tira o plugin.",
    "Licença: cabeçalho de cada arquivo de fonte do plugin e arquivos LICENSE/COPYING; recursos (nibs, "
    "imagens, modelos) e cópias de terceiros não são avaliados, e uma cópia de terceiros deixa a publicação "
    "pendente. Não é parecer jurídico.",
]


# ---------------------------------------------------------------- kit declarations

def load_kit(dirs):
    """Objective-C declarations of the porting kit and its compatibility aliases."""
    header_dirs = sorted({path.parent for directory in dirs for path in Path(directory).rglob("*.h")})
    kit = inv.load_sdk(header_dirs)
    kit.aliases = {}
    kit.diverts = set()
    # Every path an import can name a kit header by: its file name, and the name
    # with the folders above it, through the symbolic links of the kit's Include
    # folder (`OsiriXAPI/PluginFilter.h`). Lower case: the legacy plugins were
    # built, and ported plugins are built, on case-insensitive volumes.
    kit.header_paths = set()
    for directory in dirs:
        for folder, _subdirs, files in os.walk(directory, followlinks=True):
            parts = Path(folder).relative_to(directory).parts
            for name in files:
                if name.endswith(".h"):
                    full = [part.lower() for part in parts + (name,)]
                    kit.header_paths.update("/".join(full[i:]) for i in range(len(full)))
    for directory in header_dirs:
        for path in sorted(directory.glob("*.h")):
            _, code = inv.strip_source(path.read_text(errors="replace"))
            for match in re.finditer(r"@compatibility_alias\s+([A-Za-z_]\w*)\s+([A-Za-z_]\w*)", code):
                kit.aliases[match.group(1)] = match.group(2)
            # Lookups by name the kit turns into its own (the prefix header's macros).
            kit.diverts.update(re.findall(r"(?m)^\s*#\s*define\s+(NSClassFromString|objc_getClass|objc_lookUpClass)\(",
                                          code))
    return kit


def load_plugin_kit(directory):
    """Qualified names declared by the Swift sources of the plugin API v1."""
    declared = set()
    for path in sorted(Path(directory).rglob("*.swift")) if directory and Path(directory).is_dir() else []:
        _, code = inv.strip_source(path.read_text(errors="replace"), swift=True)
        stack, pending = [], None
        token = re.compile(r"\b(struct|class|enum|extension|protocol|actor)\s+([A-Za-z_][\w.]*)|"
                           r"\bcase\s+([^\n{:]+)|\b(?:func|var|let|typealias)\s+([A-Za-z_]\w*)|([{}])")
        for match in token.finditer(code):
            inside_type = not stack or stack[-1] is not None
            prefix = ".".join(s for s in stack if s)
            if match.group(1):
                if inside_type:
                    pending = match.group(2)
                    if match.group(1) != "extension":
                        declared.add(".".join(filter(None, [prefix, match.group(2)])))
            elif match.group(3) and inside_type and stack:
                for part in inv.flatten_depth0(match.group(3)).split(","):
                    name = re.match(r"\s*([A-Za-z_]\w*)", part)
                    if name:
                        declared.add(prefix + "." + name.group(1))
            elif match.group(4) and inside_type:
                declared.add(".".join(filter(None, [prefix, match.group(4)])))
            elif match.group(5) == "{":
                stack.append(pending)
                pending = None
            elif match.group(5) == "}" and stack:
                stack.pop()
    return declared


class Coverage:
    """What the kit (Objective-C headers) and the plugin API v1 (Swift names) declare, and the legacy SDK."""

    def __init__(self, kit, v1, legacy):
        self.kit = kit
        self.v1 = v1
        self.legacy = legacy

    def kit_classes(self, legacy):
        names = []
        if legacy in self.kit.aliases:
            names.append(self.kit.aliases[legacy])
        if legacy in self.kit.classes:
            names.append(legacy)
        return names

    def has_class(self, legacy):
        return any(name in self.kit.defined for name in self.kit_classes(legacy))

    def has_selector(self, legacy, selector):
        return any(self.kit.lookup(name, selector)[1] for name in self.kit_classes(legacy))

    def has_member(self, legacy, member):
        for name in self.kit_classes(legacy):
            if self.kit.ivar(name, member)[0] or self.kit.prop(name, member)[0] or self.kit.lookup(name, member)[1]:
                return True
        return False

    def has_symbol(self, name):
        return name in self.kit.notifications or name in self.kit.constants or name in self.kit.functions

    def has_header(self, target):
        path = "/".join(part for part in target.lower().split("/") if part not in ("", "."))
        return path in getattr(self.kit, "header_paths", ())

    def legacy_header(self, target):
        """The legacy SDK's own spelling of a header the plugin imports, or None."""
        base = target.split("/")[-1].lower()
        return next((name for name in self.legacy.headers if name.lower() == base), None)

    def has_any_selector(self, selector):
        return selector in self.kit.selectors

    def diverts_classes(self):
        return "NSClassFromString" in getattr(self.kit, "diverts", ())


# ---------------------------------------------------------------- classification

def candidates(label):
    return [c for c in label.split("|") if c and c != "…"]


def chosen_class(names, referenced=()):
    """The class an ambiguous call most likely goes to: one the kit is expected to
    offer, else one the plugin names elsewhere, else the first."""
    for preferred in PREFERRED_CLASSES:
        if preferred in names:
            return preferred
    for name in names:
        if name in referenced:
            return name
    return names[0]


def stage_of(cls, selector=None):
    for class_pattern, selector_pattern, stage in STAGE_RULES:
        if re.fullmatch(class_pattern, cls) and (selector_pattern is None or
                                                 (selector is not None and re.search(selector_pattern, selector))):
            return stage
    return AREA_STAGE[inv.area_of(cls)]


def gaps_of(plugin, cover, selector_strings=(), imports=None):
    """Every legacy item the plugin relies on, covered or not. `imports` gives the
    file and line of each `#import`/`#include` target, for the header items."""
    items = {}

    def add(kind, name, area, stage, covered, refs=1, by=None, attribution=None, where=None, reason=None):
        key = (kind, name)
        if key in items:
            items[key]["refs"] += refs
            return
        items[key] = {"kind": kind, "name": name, "area": area, "stage": stage, "covered": covered,
                      "by": (by or "kit") if covered else None, "refs": refs}
        if attribution:
            items[key]["attribution"] = attribution
        if where:
            items[key]["where"] = where
        if reason and not covered:
            items[key]["reason"] = reason

    divert = cover.diverts_classes()

    def dynamic_reason(kind):
        return DYNAMIC_REASONS.get(kind) if divert or kind == "dlopen/dlsym" else None

    referenced = {entry["class"] for entry in plugin["classes"]}
    for entry in plugin["selectors"]:
        label, selector = entry["class"], entry["selector"]
        # The inventory shows at most three declaring classes of an ambiguous selector.
        names = sorted(cover.legacy.selectors.get(selector, ())) if "|" in label else []
        names = names or candidates(label) or [label]
        cls = chosen_class(names, referenced)
        covered = any(cover.has_selector(c, selector) for c in names)
        name = "%s %s" % (cls, selector)
        attribution = None
        if entry["how"] in ("name-only", "swift-member"):
            attribution = "por nome"
        elif "ambiguous" in entry["how"]:
            attribution = "ambíguo: " + label
        add("chamada", name, inv.area_of(cls), stage_of(cls, selector), covered, entry["refs"],
            attribution=attribution)
    for key, kind in (("selectors_not_in_sdk", "chamada fora do SDK"),
                      ("host_methods_declared_by_plugin", "método privado do host")):
        for entry in plugin[key]:
            add(kind, "%s %s" % (entry["class"], entry["selector"]), inv.area_of(entry["class"]),
                stage_of(entry["class"], entry["selector"]), cover.has_selector(entry["class"], entry["selector"]),
                entry["refs"])
    for entry in plugin["ivars_and_attributes"]:
        add("ivar/atributo", "%s.%s" % (entry["class"], entry["name"]), inv.area_of(entry["class"]),
            stage_of(entry["class"], entry["name"]), cover.has_member(entry["class"], entry["name"]), entry["refs"])
    for key, kind, field in (("subclasses_of_host", "subclasse", "host_super"),
                             ("categories_on_host", "categoria", "class")):
        for entry in plugin[key]:
            cls = entry[field]
            add(kind, "%s de %s" % (kind, cls), inv.area_of(cls), stage_of(cls), cover.has_class(cls), entry["refs"])
    for entry in plugin["kvc_keys"]:
        # A key belongs to the host only when a host class the plugin names declares it.
        first = entry["key"].split(".")[0].lstrip("@")
        owners = sorted(name for name, info in cover.legacy.classes.items()
                        if first in info["props"] and name in referenced)
        if not owners:
            continue
        stage = "database" if any(inv.area_of(o) == "database" for o in owners) else "dynamic"
        add("chave KVC", "%s (%s)" % (entry["key"], ",".join(owners)), inv.area_of(owners[0]), stage,
            any(cover.has_member(o, first) for o in owners), entry["refs"],
            reason=dynamic_reason("key") if stage == "dynamic" else None)
    for entry in plugin["notifications"]:
        if entry["declared_by_host"]:
            # A viewer's and its ROIs' events reach the plugin with the kit's
            # objects (the viewer stage); the others are integration.
            area = inv.notification_area(entry["name"])
            viewer = area in ("viewer", "roi") and not re.search(r"DB|Database", entry["name"])
            add("notificação", entry["name"], area, "viewer" if viewer else "network",
                cover.has_symbol(entry["name"]), entry["refs"])
    for entry in plugin["host_functions_and_constants"]:
        name = entry["name"]
        add("função/constante", name, "other", "core", cover.has_symbol(name.rstrip("()")), entry["refs"])
    imports = imports or {}
    for target, refs in plugin["host_headers_missing_from_sdk"].items():
        base = target.split("/")[-1]
        third = any(pattern.search(base) for label, pattern in inv.THIRD_PARTY_HINTS if label == "DCMTK")
        stage = "libraries" if third else stage_of(base.rsplit(".", 1)[0])
        add("header fora do SDK", target, inv.area_of(base), stage, cover.has_header(target), refs,
            where=imports.get(target))
    # A header of the legacy SDK that the kit does not have: the import itself does not compile.
    for target, refs in sorted(plugin["imports"].get("host", {}).items()):
        if target in plugin["host_headers_missing_from_sdk"]:
            continue
        base = cover.legacy_header(target) or target.split("/")[-1]
        third = any(pattern.search(base) for label, pattern in inv.THIRD_PARTY_HINTS if label == "DCMTK")
        stage = "libraries" if third else stage_of(base.rsplit(".", 1)[0])
        add("header do SDK", target, inv.area_of(base), stage, cover.has_header(target), refs,
            where=imports.get(target))
    for entry in plugin["dynamic_literals"]:
        if entry["kind"] == "class" and entry["literal"] in cover.legacy.defined:
            # Without the divert the lookup finds the application's class, whatever the kit has.
            add("acesso dinâmico", 'NSClassFromString(@"%s")' % entry["literal"], inv.area_of(entry["literal"]),
                "dynamic", divert and cover.has_class(entry["literal"]), entry["refs"],
                reason=dynamic_reason("class"))
        elif entry["kind"] == "entity":
            # The kit's model has the legacy entities whose class it offers, and
            # evaluates the fetches of its context over the plugin API.
            entity_class = KIT_ENTITIES.get(entry["literal"])
            add("acesso dinâmico", "entidade Core Data %s" % entry["literal"], "database", "database",
                bool(entity_class) and cover.has_class(entity_class), entry["refs"])
    for selector, refs in sorted(Counter(selector_strings).items()):
        if selector in cover.legacy.selectors and selector not in cover.legacy.system_selectors:
            add("acesso dinâmico", 'NSSelectorFromString(@"%s")' % selector, "other", "dynamic",
                cover.has_any_selector(selector), refs, reason=dynamic_reason("selector"))
    for kind, refs in plugin["dynamic"].items():
        if kind in DYNAMIC_FEATURES:
            add("acesso dinâmico", kind, "other", "dynamic", False, refs, reason=dynamic_reason(kind))
    for library, refs in plugin["third_party"].items():
        add("biblioteca própria", library, "other", LIBRARY_STAGES.get(library, "libraries"), False, refs)
    for kind, refs in plugin["obsolete"].items():
        if kind in PLATFORM_STAGES:
            add("plataforma", kind, "other", PLATFORM_STAGES[kind], False, refs,
                reason=dynamic_reason(kind) if PLATFORM_STAGES[kind] == "dynamic" else None)
    for plist in plugin["plists"]:
        plugin_type = plist.get("pluginType")
        if plugin_type is None:
            continue
        symbol, stage = PLUGIN_TYPES.get(plugin_type, (None, "none"))
        add("tipo de plugin", "pluginType %s" % plugin_type, "menus-tools", stage,
            bool(symbol) and symbol in cover.v1, by="API v1")
    return sorted(items.values(), key=lambda g: (STAGES.index(g["stage"]), g["kind"], g["name"]))


def source_facts(paths):
    """OpenGL and QuickTime/QTKit uses in the plugin's own sources, with file and line, the
    selectors named by strings (NSSelectorFromString, sel_registerName), and the file and line
    of each `#import`/`#include` target."""
    holder = inv.PluginScan("", "", [])
    uses = defaultdict(list)
    selector_strings = []
    imports = defaultdict(list)
    for root in paths:
        for path in inv.walk([root], holder):
            if path.suffix not in inv.SOURCE_SUFFIXES:
                continue
            nc, code = inv.strip_source(path.read_text(errors="replace"), swift=path.suffix == ".swift")
            selector_strings += re.findall(r"(?:NSSelectorFromString|sel_registerName)\s*\(\s*@?\"([\w:]+)\"", nc)
            relative = path.relative_to(root) if Path(root).is_dir() else path.name
            for number, (comment_free, text) in enumerate(zip(nc.splitlines(), code.splitlines()), 1):
                is_import = re.match(r"\s*(#\s*(import|include)|import\s)", comment_free)
                target = re.match(r"\s*#\s*(?:import|include)\s*[<\"]([^>\"]+)[>\"]", comment_free)
                if target:
                    imports[target.group(1).strip()].append({"file": str(relative), "line": number})
                for label, pattern in OUT_PLATFORMS:
                    hit = pattern.search(comment_free if is_import else text)
                    if hit:
                        uses[label].append({"file": str(relative), "line": number, "text": hit.group(0).strip(),
                                            "use": "import" if is_import else "uso"})
    platforms = {label: {"uses": sum(1 for u in found if u["use"] == "uso"),
                         "imports": sum(1 for u in found if u["use"] == "import"),
                         "evidence": [u for u in found if u["use"] == "uso"][:5] or found[:3]}
                 for label, found in uses.items()}
    return platforms, selector_strings, dict(imports)


def licence_of(paths):
    """Whether every source file of the plugin declares a permissive licence and none a copyleft one."""
    holder = inv.PluginScan("", "", [])
    files, plugin_files = [], []
    for root in paths:
        for path in inv.walk([root], holder):
            if path.suffix in inv.SOURCE_SUFFIXES:
                files.append(path)
            elif re.match(r"(?i)^(license|licence|copying|copyright|notice)", path.name):
                plugin_files.append(path)
    plugin_permissive, plugin_copyleft = set(), set()
    for path in plugin_files:
        text = path.read_text(errors="replace")[:6000]
        plugin_permissive.update(name for name, pattern in PERMISSIVE if re.search(pattern, text))
        plugin_copyleft.update(name for name, pattern in COPYLEFT if re.search(pattern, text))
    counts = Counter()
    for path in files:
        header = "\n".join(path.read_text(errors="replace").splitlines()[:80])
        copyleft = [name for name, pattern in COPYLEFT if re.search(pattern, header)]
        permissive = [name for name, pattern in PERMISSIVE if re.search(pattern, header)]
        if copyleft:
            counts["LGPL" if "LGPL" in copyleft else "GPL"] += 1
        elif permissive or (plugin_permissive and not plugin_copyleft):
            counts["permissiva"] += 1
        elif plugin_copyleft:
            counts["GPL (arquivo da pasta)"] += 1
        else:
            counts["sem licença"] += 1
    third_party = sorted(v["path"] for v in holder.vendored if not NOT_SHIPPED.search(v["path"]))
    publishable = bool(files) and counts["permissiva"] == len(files) and not third_party
    if not files:
        reason = "sem fontes"
    elif publishable:
        reason = "todos os %d arquivos com licença permissiva" % len(files)
    else:
        parts = ["%s em %d" % (k, v) for k, v in sorted(counts.items()) if k != "permissiva"]
        if third_party:
            parts.append("cópias de terceiros não avaliadas (%s)" % ", ".join(third_party[:3]))
        reason = "; ".join(parts) + " de %d arquivos" % len(files)
    return {"publishable": publishable, "files": len(files), "counts": dict(counts), "reason": reason,
            "third_party_copies": third_party}


def band_of(plugin, gaps):
    """simple: only the core and the converter; medium: also database, viewer, network or dynamic access;
    complex: own libraries, a need no stage covers, or a subclass of a host class other than PluginFilter."""
    stages = {g["stage"] for g in gaps if not g["covered"]}
    deep = [e["host_super"] for e in plugin["subclasses_of_host"] if e["host_super"] != "PluginFilter"]
    if stages & {"libraries", "none"} or deep:
        return "complexo"
    if stages - {"core", "converter"}:
        return "médio"
    return "simples"


def converter_items(conversion):
    """What the converter left in a plugin: source items by category, and the build notes."""
    if not conversion or "error" in conversion:
        return None
    left = defaultdict(list)
    notes = []
    for item in conversion.get("unconverted", []):
        if item["category"] == "build":
            notes.append(item)
        else:
            left[item["category"]].append(item)
    return {"left": left, "notes": notes}


def apply_converter(gaps, conversion):
    """The converter's stage, covered by its report: a platform item of that stage is
    covered when the report leaves nothing of its kind in the plugin."""
    items = converter_items(conversion)
    if items is None:
        return
    for g in gaps:
        if g["kind"] == "plataforma" and g["stage"] == "converter" and not items["left"].get(g["name"]):
            g["covered"] = True
            g["by"] = "conversor"


def converter_summary(conversion):
    if conversion is None:
        return None
    if "error" in conversion:
        return {"error": conversion["error"]}
    items = converter_items(conversion)
    rewrites = Counter(r["category"] for r in conversion.get("rewrites", []))
    return {"module": conversion.get("module"), "rewrites": dict(rewrites),
            "projectChanges": sorted({c["category"] for c in conversion.get("projectChanges", [])}),
            "left": [{k: item.get(k) for k in ("category", "file", "line", "text")}
                     for category in sorted(items["left"]) for item in items["left"][category]],
            "notes": [item["text"] for item in items["notes"]]}


def classify(plugin, cover, root, conversions=None):
    paths = [root / plugin["name"]]
    platforms, selector_strings, imports = source_facts(paths)
    gaps = gaps_of(plugin, cover, selector_strings, imports)
    conversion = (conversions or {}).get(plugin["name"])
    apply_converter(gaps, conversion)
    out = []
    if plugin["name"] in EPIC_REASON:
        out.append(EPIC_REASON[plugin["name"]])
    for label, found in sorted(platforms.items()):
        if found["uses"] and label not in PORT_DROPS.get(plugin["name"], {}):
            out.append("depende de " + label)
    if not plugin["plugin_products"] and "não é plugin" not in out:
        out.append("não é plugin")
    missing = [g for g in gaps if not g["covered"]]
    final = FINAL.get(plugin["name"])
    if plugin["name"] in PORTED:
        state = final[0]
    elif out and out[0] == PLANNED:
        state = PLANNED
    elif out:
        state = "fora"
    elif final:
        state = final[0]
    elif not missing:
        state = "portável, sem faltas"
    else:
        state = "portável, com faltas"
    return {
        "name": plugin["name"],
        "plugin": bool(plugin["plugin_products"]),
        "plugin_type": [p.get("pluginType") for p in plugin["plists"] if p.get("pluginType")][:1],
        "state": state,
        "final": final[1] if final else None,
        "out": out,
        "band": "fora" if out else band_of(plugin, gaps),
        "partial": plugin["name"] in PARTIAL,
        "platforms": platforms,
        "licence": licence_of(paths),
        "gaps": gaps,
        "missing_by_stage": dict(Counter(g["stage"] for g in missing)),
        "converter": converter_summary(conversion),
        "covered": sum(1 for g in gaps if g["covered"]),
        "total": len(gaps),
    }


# ---------------------------------------------------------------- report

def stage_label(stage, issues):
    return "%s%s" % (stage, " (%s)" % issues[stage] if stage in issues else "")


def summary(rows):
    plugins = [r for r in rows if r["plugin"]]
    portable = [r for r in plugins if not r["out"]]
    bands = Counter(r["band"] for r in plugins)
    out_reasons = Counter(r["out"][0] for r in plugins if r["out"])
    stage_plugins, stage_items = Counter(), defaultdict(set)
    top, users = Counter(), defaultdict(set)
    for r in portable:
        for g in r["gaps"]:
            if g["covered"]:
                continue
            stage_items[g["stage"]].add((g["kind"], g["name"]))
            key = (g["kind"], g["name"], g["area"], g["stage"])
            top[key] += g["refs"]
            users[key].add(r["name"])
        for stage in r["missing_by_stage"]:
            stage_plugins[stage] += 1
    return {
        "plugins": len(plugins),
        "not_plugins": [r["name"] for r in rows if not r["plugin"]],
        "portable": len(portable),
        "ported": sum(1 for r in plugins if r["state"] in (VERIFIED, UNCHECKED)),
        "verified": sum(1 for r in plugins if r["state"] == VERIFIED),
        "unchecked": sum(1 for r in plugins if r["state"] == UNCHECKED),
        "lacking": sum(1 for r in plugins if r["state"] == LACKING),
        "out": len(plugins) - len(portable),
        "out_reasons": dict(out_reasons),
        "platform_users": {label: sum(1 for r in plugins if r["platforms"].get(label, {}).get("uses"))
                           for label, _ in OUT_PLATFORMS},
        "bands": dict(bands),
        "states": dict(Counter(r["state"] for r in plugins)),
        "publishable": [r["name"] for r in portable if r["licence"]["publishable"]],
        "stages": {s: {"plugins": stage_plugins[s], "items": len(stage_items[s])} for s in STAGES},
        "top_missing": [{"kind": k[0], "name": k[1], "area": k[2], "stage": k[3], "plugins": len(users[k]),
                         "refs": refs}
                        for k, refs in sorted(top.items(), key=lambda kv: (-len(users[kv[0]]), -kv[1], kv[0]))[:60]],
    }


def esc(text):
    return str(text).replace("|", "\\|")


def markdown(report, issues):
    s = report["summary"]
    out = ["# Matriz de compatibilidade dos plugins antigos (gerada)\n",
           "Gerada por `tools/legacy-plugin-compatibility-matrix.py`. Não editar à mão; rodar de novo.\n",
           "## Entradas\n"]
    for label, value in report["inputs"].items():
        out.append("- %s: %s" % (label, value))
    out.append("\n## Contagem\n")
    out.append("| Item | Valor |")
    out.append("| --- | --- |")
    out.append("| Plugins da coleção | %d |" % s["plugins"])
    out.append("| Fora | %d |" % s["out"])
    for reason, count in sorted(s["out_reasons"].items(), key=lambda kv: -kv[1]):
        out.append("| — fora: %s | %d |" % (reason, count))
    for label, count in s["platform_users"].items():
        out.append("| Usam %s (motivo principal ou não) | %d |" % (label, count))
    out.append("| Portáveis (base da cobertura) | %d |" % s["portable"])
    out.append("| Portados | %d |" % s["ported"])
    out.append("| — portados e verificados | %d |" % s["verified"])
    out.append("| — portados sem checagem completa | %d |" % s["unchecked"])
    out.append("| Portáveis que ficaram fora pelo que falta | %d |" % s["lacking"])
    out.append("| Cobertura (portados / portáveis) | %d / %d |" % (s["ported"], s["portable"]))
    for band in ("simples", "médio", "complexo"):
        out.append("| Faixa %s | %d |" % (band, s["bands"].get(band, 0)))
    for state, count in sorted(s["states"].items()):
        out.append("| Estado: %s | %d |" % (state, count))
    out.append("| Portáveis publicáveis (licença permissiva em todos os arquivos) | %d%s |"
               % (len(s["publishable"]), ": " + ", ".join(s["publishable"]) if s["publishable"] else ""))
    out.append("\nProjetos da coleção que não são plugin: %s.\n" % (", ".join(s["not_plugins"]) or "—"))
    out.append("## Etapas\n")
    out.append("| Etapa | Cobre | Plugins portáveis com falta | Itens distintos em falta |")
    out.append("| --- | --- | --- | --- |")
    for stage in STAGES:
        out.append("| %s | %s | %d | %d |" % (stage_label(stage, issues), STAGE_TITLES[stage],
                                             s["stages"][stage]["plugins"], s["stages"][stage]["items"]))
    out.append("\n## Faixas\n")
    out.append("- **simples**: só faltam o núcleo e o conversor.")
    out.append("- **médio**: faltam também banco, viewer e janelas, rede ou acesso dinâmico.")
    out.append("- **complexo**: precisa de biblioteca própria, de algo que nenhuma etapa cobre, ou subclassa uma "
               "classe do host que não é `PluginFilter`.")
    out.append("- **fora**: lista do mantenedor (incluída a incorporação prevista no IsiX), OpenGL, "
               "QuickTime/QTKit ou não é plugin.\n")
    out.append("## Limites\n")
    for limit in LIMITS:
        out.append("- " + limit)
    out.append("\n## Matriz\n")
    out.append("| Plugin | Tipo | Faixa | Estado | Fora: motivo | OpenGL / QuickTime | Faltas por etapa | "
               "Cobertos | Licença: publicar? |")
    out.append("| --- | --- | --- | --- | --- | --- | --- | --- | --- |")
    for r in report["plugins"]:
        platforms = "; ".join("%s: %d uso(s)%s" % (label, f["uses"], ", %d import(s)" % f["imports"]
                                                   if f["imports"] else "")
                              for label, f in sorted(r["platforms"].items())) or "—"
        missing = ", ".join("%s %d" % (stage_label(stage, issues), r["missing_by_stage"][stage])
                            for stage in STAGES if stage in r["missing_by_stage"]) or "—"
        name = r["name"] + (" (parcial)" if r["partial"] else "")
        out.append("| %s | %s | %s | %s | %s | %s | %s | %d de %d | %s |" % (
            esc(name), esc(", ".join(r["plugin_type"]) or "—"), r["band"], r["state"],
            esc("; ".join(r["out"]) or "—"), esc(platforms), esc(missing), r["covered"], r["total"],
            esc(("sim — " if r["licence"]["publishable"] else "não — ") + r["licence"]["reason"])))
    out.append("\n## Estado final dos portáveis\n")
    projects = report.get("ported_projects")
    if projects is not None:
        out.append("Projetos convertidos lidos de %s.\n" % projects["input"])
    out.append("| Plugin | Estado | Motivo, prova ou o que falta | Projeto convertido | Correções à mão |")
    out.append("| --- | --- | --- | --- | --- |")
    for r in report["plugins"]:
        if r["out"]:
            continue
        project = r.get("project") or {}
        out.append("| %s | %s | %s | %s | %s |" % (
            esc(r["name"]), r["state"], esc(r.get("final") or "—"),
            ("`%s`" % project["module"]) if project.get("module") else ("ausente" if projects is not None and r["state"] in
                                                                            (VERIFIED, UNCHECKED) else "—"),
            ("%d arquivo(s)" % project["handFixedFiles"] if project.get("handFixedFiles") else
             ("nenhuma" if project.get("module") else "—"))))
    out.append("\n## APIs mais faltantes nos plugins portáveis\n")
    out.append("| Item | Tipo | Área | Etapa | Plugins | Referências |")
    out.append("| --- | --- | --- | --- | --- | --- |")
    for entry in s["top_missing"]:
        out.append("| `%s` | %s | %s | %s | %d | %d |" % (esc(entry["name"]), entry["kind"], area_title(entry["area"]),
                                                         stage_label(entry["stage"], issues), entry["plugins"],
                                                         entry["refs"]))
    out.append("\n## Fora por OpenGL ou QuickTime/QTKit: evidências\n")
    for r in report["plugins"]:
        for label, found in sorted(r["platforms"].items()):
            if not found["uses"] and not found["imports"]:
                continue
            note = "" if found["uses"] else " — só import, não tira o plugin"
            out.append("- %s, %s%s: %s" % (r["name"], label, note, ", ".join(
                "`%s:%d` `%s`" % (e["file"], e["line"], e["text"]) for e in found["evidence"])))
    if report.get("converter"):
        out.append("\n## Conversor: o que ficou sem equivalente nos plugins portáveis\n")
        out.append("Do relatório de %s. Reescritas por tipo; depois, o que o conversor não reescreve, com "
                   "arquivo e linha no projeto convertido (`Sources/` é a pasta do plugin), e as notas do "
                   "projeto.\n" % report["converter"])
        for r in report["plugins"]:
            c = r.get("converter")
            if r["out"] or not c:
                continue
            if "error" in c:
                out.append("- %s: o conversor falhou: %s" % (esc(r["name"]), esc(c["error"])))
                continue
            rewrites = ", ".join("%s %d" % (k, v) for k, v in sorted(c["rewrites"].items())) or "nenhuma"
            left = "; ".join("%s `%s:%s` `%s`" % (i["category"], esc(i["file"]), i["line"], esc(i["text"][:80]))
                             for i in c["left"]) or "nada"
            notes = "; ".join(esc(n) for n in c["notes"]) or "nenhuma"
            out.append("- **%s** (`%s`): reescritas: %s. Sem equivalente: %s. Notas do projeto: %s."
                       % (esc(r["name"]), c["module"], rewrites, left, notes))
    out.append("\n## Faltas por plugin portável\n")
    out.append("`*` = chamada atribuída por nome ou ambígua (sem receptor tipado).\n")
    for r in report["plugins"]:
        if r["out"]:
            continue
        out.append("### %s\n" % r["name"])
        out.append("Faixa %s; %s; %d de %d itens cobertos.\n" % (r["band"], r["state"], r["covered"], r["total"]))
        by_stage = defaultdict(list)
        for g in r["gaps"]:
            if not g["covered"]:
                by_stage[g["stage"]].append(g)
        for stage in STAGES:
            if stage not in by_stage:
                continue
            items = ["`%s`%s (%s, %s%s%s)" % (esc(g["name"]), "*" if g.get("attribution") else "", g["kind"],
                                               area_title(g["area"]), where_text(g),
                                               "; motivo: " + esc(g["reason"]) if g.get("reason") else "")
                     for g in by_stage[stage]]
            out.append("- %s: %s" % (stage_label(stage, issues), "; ".join(items)))
        out.append("")
    return "\n".join(out) + "\n"


def where_text(gap, limit=3):
    """`, em `File.m:10`, `Other.h:3`` for an item found at known places."""
    where = gap.get("where") or []
    if not where:
        return ""
    places = ", ".join("`%s:%d`" % (esc(w["file"]), w["line"]) for w in where[:limit])
    return ", em " + places + (" e mais %d" % (len(where) - limit) if len(where) > limit else "")


def area_title(area):
    return inv.AREA_TITLES.get(area, area)


# ---------------------------------------------------------------- converted projects

def load_ported_projects(folder):
    """{folder of the collection: {module, handFixedFiles}} for each converted
    project of `folder` (Porting/source.json names the folder it came from)."""
    found = {}
    for source in sorted(Path(folder).glob("*/Porting/source.json")):
        project = source.parent.parent
        try:
            origin = json.loads(source.read_text())
        except ValueError:
            continue
        diff = project / "Porting" / "hand-fixes.diff"
        files = set(re.findall(r"^\+\+\+ b/(\S+)", diff.read_text(errors="replace"), re.M)) if diff.is_file() else set()
        found[origin.get("folder", project.name)] = {"module": project.name, "handFixedFiles": len(files)}
    return found


# ---------------------------------------------------------------- main

def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--api-headers", action="append", required=True, type=Path,
                        help="headers of the legacy plugin SDK (Horos.framework/Headers), repeatable")
    parser.add_argument("--collection", required=True, type=Path, help="folder of legacy plugin sources")
    parser.add_argument("--kit-headers", action="append", type=Path,
                        help="public headers of the porting kit (default: IsiXLegacyBridge when it exists)")
    parser.add_argument("--plugin-kit", type=Path, default=ROOT / "IsiXPluginKit/Sources",
                        help="Swift sources of the plugin API v1")
    parser.add_argument("--macos-sdk", type=Path, help="macOS SDK root, to recognise Cocoa selectors")
    parser.add_argument("--stage-issue", action="append", default=[],
                        help="STAGE=LABEL: the work item that covers a stage, shown in the report")
    parser.add_argument("--markdown", type=Path, help="write the Markdown matrix here (default: stdout)")
    parser.add_argument("--json", type=Path, help="write the JSON matrix here")
    parser.add_argument("--converter-report", type=Path,
                        help="report of tools/port-legacy-plugin.py --collection over the same collection")
    parser.add_argument("--ported-projects", type=Path,
                        help="the collection of converted plugins: one project per folder, with Porting/source.json")
    args = parser.parse_args(argv)
    missing = [str(p) for p in [args.collection] + args.api_headers if not p.is_dir()]
    if missing:
        print("SKIP: missing input: %s" % ", ".join(missing), file=sys.stderr)
        return MISSING_INPUT
    issues = {}
    for value in args.stage_issue:
        stage, _, label = value.partition("=")
        if stage not in STAGES or not label:
            parser.error("--stage-issue expects STAGE=LABEL with STAGE in %s" % ", ".join(STAGES))
        issues[stage] = label
    kit_dirs = args.kit_headers
    if kit_dirs is None:
        default = ROOT / "IsiXLegacyBridge"
        kit_dirs = [default] if default.is_dir() else []
    conversions, converter_input = None, None
    if args.converter_report:
        if not args.converter_report.is_file():
            print("SKIP: missing input: %s" % args.converter_report, file=sys.stderr)
            return MISSING_INPUT
        converted = json.loads(args.converter_report.read_text())
        conversions = converted.get("plugins", {})
        converter_input = "`%s`: %d pastas, revisão %s da coleção, %d falha(s)" % (
            converted.get("converter", "tools/port-legacy-plugin.py"), len(conversions),
            converted.get("revision") or "desconhecida", len(converted.get("errors", [])))
    ported_projects = None
    if args.ported_projects:
        if not args.ported_projects.is_dir():
            print("SKIP: missing input: %s" % args.ported_projects, file=sys.stderr)
            return MISSING_INPUT
        ported_projects = load_ported_projects(args.ported_projects)
    legacy = inv.load_sdk(args.api_headers, args.macos_sdk)
    cover = Coverage(load_kit(kit_dirs), load_plugin_kit(args.plugin_kit), legacy)
    rows = []
    for name, path, kind in inv.collection_entries(args.collection):
        if kind == "no-sources":
            continue
        scan = inv.scan_plugin(name, kind, [path], legacy)
        row = classify(inv.to_json(scan), cover, args.collection, conversions)
        if ported_projects is not None:
            row["project"] = ported_projects.get(name)
        rows.append(row)
    git = inv.git_info(args.collection) or {}
    report = {
        "inputs": {
            "coleção": "`%s`, revisão %s" % (args.collection.name, git.get("revision") or "fora de git"),
            "SDK antigo": "%s (%d headers, %d classes, %d seletores)" % (
                ", ".join("`%s`" % "/".join(d.resolve().parts[-4:]) for d in args.api_headers), len(legacy.headers), len(legacy.classes),
                len(legacy.selectors)),
            "kit de portabilidade": ("%s: %d classes, %d aliases, %d headers" % (
                ", ".join("`%s`" % Path(d).name for d in kit_dirs), len(cover.kit.defined), len(cover.kit.aliases),
                len(cover.kit.headers)) if kit_dirs else "ausente"),
            "API v1": "`%s`: %d nomes declarados" % (args.plugin_kit.parent.name if args.plugin_kit.name == "Sources"
                                                     else args.plugin_kit.name, len(cover.v1)),
            "conversor": converter_input or "sem relatório: a etapa do conversor fica em falta",
        },
        "converter": converter_input,
        "ported_projects": None if ported_projects is None else {
            "input": "`%s`: %d projetos" % (args.ported_projects.name, len(ported_projects)),
            "missing": sorted(r["name"] for r in rows if r["state"] in (VERIFIED, UNCHECKED) and not r.get("project")),
            "unexpected": sorted(name for name in ported_projects if name not in PORTED)},
        "stages": {s: {"title": STAGE_TITLES[s], "issue": issues.get(s)} for s in STAGES},
        "limits": LIMITS,
        "plugins": rows,
    }
    report["summary"] = summary(rows)
    if ported_projects is not None:
        report["inputs"]["plugins convertidos"] = report["ported_projects"]["input"]
    text = markdown(report, issues)
    if args.markdown:
        args.markdown.write_text(text)
    else:
        sys.stdout.write(text)
    if args.json:
        args.json.write_text(json.dumps(report, indent=1, ensure_ascii=False, sort_keys=True) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
