# Contrato do seletor de modificação DICOM por argumentos

`+[XMLController modifyDicom:encoding:]` mantém o seletor, os tipos Objective-C e
retorno `int`. `params[0]` é o nome do programa, seguido de opções/valores e um
ou mais arquivos. Não confundir com o overload `modifyDicom:dicomFiles:reasons:`:
este contrato não modifica suas políticas de edição nem de anonimização.

## Consumidores e implementação

A busca dirigida no checkout encontra a declaração em
`XMLControllerDCMTKCategory.h` e a implementação da categoria, sem chamadas
internas ao overload CLI. O empacotador `API-Headers.pl` publica a declaração;
plugins externos podem chamá-la. A ausência de chamadas internas não autoriza
remover o seletor. Os headers mdf* também eram copiados pelo empacotador genérico,
mas as classes Mdf eram detalhes C++ do engine retirado, não a fachada mantida.
Não há uso delas fora dos dois pares mdf* e do antigo wrapper; o include das
preferências era desnecessário. O par da pasta de preferências é independente.

O adapter original do host `HorosDICOMCLI.mm` usa `OFCommandLine`, `DcmPath`,
`DcmFileFormat`, `DcmItem`, o dicionário e o gerador de UID do DCMTK. Nenhum arquivo
`dcmdata/apps` é copiado ou compilado no app. A origem da biblioteca é o gitlink
DCMTK, revisão pública `414cbd77b01d6f0138ea58a7eca34b2c19157c78`; seu `COPYRIGHT`
e os notices entregues pelo catálogo de licenças permanecem. Os arquivos mdf*
antigos eram de Michael Onken/OFFIS (2003–2005), adaptados pelo host; sua remoção
não atribui esse código ao autor do novo adapter.

## Opções aceitas

Os nomes longos e curtos abaixo são equivalentes. O parser upstream também
mantém arquivos de argumentos `@arquivo`; as opções de cada grupo escolhem o
último valor. As operações são executadas na ordem em que foram passadas.

| Grupo | Nome longo e alias curto |
| --- | --- |
| Informação | `--help -h`, `--version`, `--debug -d`, `--verbose -v` |
| Erros | `--ignore-errors -ie` |
| Entrada | `--read-file +f`, `--read-file-only +fo`, `--read-dataset -f` |
| TS de entrada | `--read-xfer-auto -t=`, `--read-xfer-detect -td`, `--read-xfer-little -te`, `--read-xfer-big -tb`, `--read-xfer-implicit -ti` |
| Parsing | `--accept-odd-length +ao`, `--assume-even-length +ae`, `--enable-correction +dc`, `--disable-correction -dc` |
| Deflate (build com zlib) | `--bitstream-deflated +bd`, `--bitstream-zlib +bz` |
| Operações (um argumento) | `--insert-tag -i`, `--modify-tag -m`, `--modify-all-tags -ma`, `--erase-tag -e`, `--erase-all-tags -ea` |
| UID | `--gen-stud-uid -gst`, `--gen-ser-uid -gse`, `--gen-inst-uid -gin`, `--no-meta-uid -nmu` |
| Saída | `--write-file +F`, `--write-dataset -F` |
| TS de saída | `--write-xfer-same +t=`, `--write-xfer-little +te`, `--write-xfer-big +tb`, `--write-xfer-implicit +ti` |
| VR | `--enable-new-vr +u`, `--disable-new-vr -u` |
| Group length | `--group-length-recalc +g=`, `--group-length-create +g`, `--group-length-remove -g` |
| Comprimentos | `--length-explicit +le`, `--length-undefined -le` |
| Padding | `--padding-retain -p=`, `--padding-off -p`, `--padding-create +p` (dois inteiros não negativos até Uint32) |

Default: leitura automática, TS original, formato de arquivo, explicit lengths,
recalcular group lengths existentes, sem padding (valor efetivo do engine
anterior), atualizar UIDs relacionados e não ignorar erros. TS explícita na
entrada exige `--read-dataset`; padding retain/create conflita com dataset-only.
Debug/verbose são aceitos; diagnósticos de erro não imprimem valores DICOM.
Help/version retornam sucesso e informação, sem encerrar o app. Argumentos vazios,
tipos inválidos, opções/valores inválidos e strings não representáveis retornam
erro em vez de fazer `exit()` ou converter silenciosamente para um ponteiro NULL.

## Tags, paths, encoding e erros

- Tags numéricas `(gggg,eeee)` ou keywords do dicionário atual. Insert cria ou
  substitui a folha; modify exige folha existente. Erase exige existência.
  Valor vazio é um valor, e não remoção. O primeiro `=` separa path e valor.
- Paths zero-based, com profundidade arbitrária dentro dos limites do leitor:
  `Sequence[0].Sequence[1].Tag`. Sequências e itens precisam existir, mesmo no
  insert; não há wildcard, criação automática de itens ou narrowing de índice.
- Modify-all modifica todas as ocorrências da tag e ignora o prefixo de path,
  como o engine anterior. Erase-all busca recursivamente abaixo do item
  endereçado. VRs existentes usam o `putString` da biblioteca, sem substituir
  o elemento ou perder o private creator. SQ/binário seguem suas recusas
  upstream, sem adotar políticas do editor NSArray.
- Insert de tag desconhecida, inclusive privada sem VR do dicionário, cria UN
  vazio. Quando creator+tag são conhecidos, usa o VR de seu contexto. Não
  inventa private creators nem reatribui blocos.
- Insert/modify recusam grupo 0000 e grupos inválidos 0001/0003/0005/0007/FFFF;
  grupo 0002 no dataset continua permitido pelo contrato antigo. Erase não
  restringe o grupo. UIDs SOP modificados/insertados atualizam os pares da meta
  informação salvo `-nmu`; `-gin` sempre atualiza, como antes. Erase não força
  atualização de UID na meta informação.
- `encoding` controla os bytes dos valores, sem conversão automática do charset
  do arquivo; `SpecificCharacterSet` é editável por tag como antes. Unicode não
  representável/NUL retorna erro antes de escrever. Paths de arquivo usam UTF-8
  independentemente do encoding dos valores. Flags globais de I/O são restauradas.
- Retorno zero significa sucesso. Retorno positivo conta operações/arquivos
  falhos; erro de argumento retorna um. Todos os jobs do arquivo são tentados.
  Mantém-se a política cumulativa do lote: depois de um erro, os próximos arquivos
  também não são publicados, salvo `-ie`; ignorar erros permite publicar as
  operações válidas, mas não zera a contagem. Uma falha de load/materialização
  conta uma vez e não executa os jobs daquele arquivo.

## Publicação e integridade

Entrada de arquivo usa `HorosDCMTKSeekableInput`: o owner preserva a fonte e,
para deflated, o backing expandido seekable até o save terminar, sem
`loadAllDataIntoMemory`. A TS deflated original vem da meta informação e é
preservada quando não se pede conversão; não se toma a TS LE do backing como a
TS original. `read-file-only` conserva a recusa de meta/TS ausente. A flag detect
conserva a detecção native do DCMTK e não muda a TS comprimida declarada.

`read-dataset` continua usando diretamente `DcmFileFormat.loadFile` com TS
unknown/LE/BE/implicit selecionada pelo CLI e fonte seekable intacta. Esse
contrato não oferece TS deflated forçada para entrada de dataset sem meta;
não é adicionado um fallback ou normalização para fazê-la ser aceita. Valores
nativos também ficam diferidos até o save. A saída completa é gravada em temporário no mesmo diretório e seu
fechamento/flush são verificados. Depois se publica um backup completo `.bak`
e se substitui o original por rename. Falha de operação, leitura, truncamento,
criação/gravação/fechamento do temporário ou backup preserva o original. Não é
necessário restaurar um original que nunca foi movido para fora do caminho.
Backups prévios ficam intactos até a publicação; temporários são removidos em
todas as saídas. Arquivos especiais e symlinks não são publicados. Permissões
POSIX e bytes são preservados no backup; não há contrato de cópia de xattrs.

TS não solicitada e payloads de pixels permanecem. Conversão de TS explícita
exige `canWriteXfer` e nunca faz fallback silencioso. Dataset-only continua
revertendo para formato de arquivo quando os pixels são encapsulados. Mudanças
solicitadas de endian/VR podem alterar os bytes codificados preservando valores.
Normalizações upstream de meta informação, group lengths, comprimentos e padding
não prometem arquivo inteiro byte a byte igual.

## Teste focado

`python3 tests/test-dicom-cli.py` compila o seletor corrente e o adapter, com os
archives do build normal. `--install CAMINHO` permite usar headers/archives de
um build existente somente como entradas de leitura, sem compartilhar outputs.
Requer pydicom 3; dependências ausentes são skip (exit 2). Dados sintéticos são
criados em temporário, e pydicom verifica a árvore, valores, VRs, pixels e TS.
A declaração pública também compila em Objective-C e Objective-C++. Não usa
fixtures históricas nem o banco/app do usuário.
