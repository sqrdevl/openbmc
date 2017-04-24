#!/usr/bin/env bash

set -e

SOURCE="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SCRIPTS="$SOURCE/signing"

if [ "$#" -ne 3 ]; then
  echo "Invalid parameters:"
  echo "./build.sh POKY_BUILD INPUT_FLASH OUTPUT_DIR"
  echo ""
  echo "  POKY_BUILD: Directory of build-dir within poky"
  echo "  INPUT_FLASH: The input flash-BOARD file"
  echo "  OUTPUT_DIR: Existing directory that will contain output flashes"
  exit 1
fi

PYTHON=`which python2 || true`
if [ "$PYTHON" = "" ]; then
  echo "Error: cannot find 'python2'"
  exit 1
fi

DTC=`which dtc || true`
if [ "$DTC" = "" ]; then
  echo "Error: cannot find 'dtc' (please install device-tree-compiler)"
  exit 1
fi

OPENSSL=`which openssl || true`
if [ "$OPENSSL" = "" ]; then
  echo "Error: cannot find 'openssl'"
  exit 1
fi

PYCRYPTO=`$PYTHON -c 'import Crypto' 2>&1 &> /dev/null; echo $?`
if [ ! "$PYCRYPTO" = "0" ]; then
  echo "Error: Python ($PYTHON) cannot import 'Crypto' (install python-crypto)"
  exit 1
fi

JINJA2=`$PYTHON -c 'import jinja2' 2>&1 &> /dev/null; echo $?`
if [ ! "$JINJA2" = "0" ]; then
  echo "Error: Python ($PYTHON) cannot import 'jinja2' (install python-jinja2)"
  exit 1
fi

POKY_BUILD="$1"
if [ ! -d "$POKY_BUILD" ]; then
  echo "Error: the POKY_BUILD argument ($POKY_BUILD) does not exist?"
  exit 1
fi

MKIMAGE="$POKY_BUILD/tmp/sysroots/x86_64-linux/usr/bin/mkimage"
if [ ! -f "$MKIMAGE" ]; then
  echo "Error: cannot find mkimage at ($MKIMAGE) have you run 'bitbake MACHINE-image'?"
  exit 1
fi

INPUT_FLASH="$2"
if [ ! -f "$INPUT_FLASH" ]; then
  echo "Error: the INPUT_FLASH argument ($INPUT_FLASH) does not exist?"
  exit 1
fi
INPUT_NAME=`basename $INPUT_FLASH`

OUTPUT_DIR="$3"
OUTPUT_DIR=`realpath $OUTPUT_DIR || echo $OUTPUT_DIR`
if [ ! -d "$OUTPUT_DIR" ]; then
  echo "Error: the OUTPUT_DIR argument ($OUTPUT_DIR) does not exist?"
  exit 1
fi

echo -e "Using scripts: \t$SCRIPTS"
echo -e "Using build: \t$POKY_BUILD"
echo -e "Using flash: \t$INPUT_FLASH"
echo -e "Using output: \t$OUTPUT_DIR"
echo -e "Using python2: \t$PYTHON"
echo -e "Using dtc: \t$DTC"
echo -e "Using openssl: \t$OPENSSL"
echo ""

DIRTY=`find $OUTPUT_DIR | wc -l`
if [ ! "$DIRTY" = "1" ]; then
  echo "Note: the OUTPUT_DIR ($OUTPUT_DIR) is not empty..."
fi

mkdir -p "$OUTPUT_DIR/kek"
openssl genrsa -F4 -out "$OUTPUT_DIR/kek/kek.key" 4096
openssl rsa -in "$OUTPUT_DIR/kek/kek.key" -pubout > "$OUTPUT_DIR/kek/kek.pub"
echo -e "\nCreated KEK (ROM key): $OUTPUT_DIR/kek/kek.{key,pub}\n"

mkdir -p "$OUTPUT_DIR/subordinate"
openssl genrsa -F4 -out "$OUTPUT_DIR/subordinate/subordinate.key" 4096
openssl rsa -in "$OUTPUT_DIR/subordinate/subordinate.key" -pubout > "$OUTPUT_DIR/subordinate/subordinate.pub"
echo -e "\nCreated Subordinate key (used to signed U-Boot and Linux): $OUTPUT_DIR/subordinate/subordinate.{key,pub}\n"

$SCRIPTS/fit-cs --template $SCRIPTS/store.dts.in $OUTPUT_DIR/kek $OUTPUT_DIR/kek/kek.dtb
$SCRIPTS/fit-cs --template $SCRIPTS/store.dts.in --subordinate --subtemplate $SCRIPTS/sub.dts.in \
  $OUTPUT_DIR/subordinate $OUTPUT_DIR/subordinate/subordinate.dtb
$SCRIPTS/fit-signsub --mkimage $MKIMAGE --keydir $OUTPUT_DIR/kek \
  $OUTPUT_DIR/subordinate/subordinate.dtb $OUTPUT_DIR/subordinate/subordinate.dtb.signed

mkdir -p $OUTPUT_DIR/flashes
rm -f $OUTPUT_DIR/flashes/*

FLASH_UNSIGNED=$OUTPUT_DIR/flashes/$INPUT_NAME.unsigned
FLASH_SIGNED=$OUTPUT_DIR/flashes/${INPUT_NAME}.signed
cp $INPUT_FLASH $FLASH_UNSIGNED

$SCRIPTS/fit-sign --mkimage $MKIMAGE --kek $OUTPUT_DIR/kek/kek.dtb \
  --signed-subordinate $OUTPUT_DIR/subordinate/subordinate.dtb.signed \
  --keydir $OUTPUT_DIR/subordinate $FLASH_UNSIGNED $FLASH_SIGNED

# Time to generate all test cases.
# cd $OUTPUT_DIR/flashes
FLASH_SIGNED=$INPUT_NAME.signed
FLASH_UNSIGNED=$INPUT_NAME.unsigned
SIZE=$(ls -l $OUTPUT_DIR/flashes/$FLASH_SIGNED | cut -d " " -f5)
SIZE=$(expr $SIZE / 1024)

# 0.0 Success case
echo "[+] Creating 0.0..."
ln -sf $FLASH_SIGNED $OUTPUT_DIR/flashes/$INPUT_NAME.CS0.0.0
ln -sf $FLASH_SIGNED $OUTPUT_DIR/flashes/$INPUT_NAME.CS1.0.0

# 3.30 Blank CS1
echo "[+] Creating 3.30..."
ln -sf $FLASH_SIGNED $OUTPUT_DIR/flashes/$INPUT_NAME.CS0.3.30
touch $OUTPUT_DIR/flashes/$INPUT_NAME.CS1.3.30
dd if=/dev/zero of=$OUTPUT_DIR/flashes/$INPUT_NAME.CS1.3.30 bs=1k count=$SIZE

# Extract 0x8:0000 - 0x8:4000 (U-Boot FIT) for modifications
dd if=$OUTPUT_DIR/flashes/$FLASH_SIGNED of=$OUTPUT_DIR/error/u-boot.dtb bs=1k skip=512 count=16
UBOOT_DTS=$OUTPUT_DIR/error/u-boot.dts
dtc -I dtb -O dts $OUTPUT_DIR/error/u-boot.dtb -o $UBOOT_DTS

function edit_dtb() {
  FLASH=$1
  DTS=$2
  dtc -I dts -O dtb $DTS -o /tmp/edit.dtb
  dd if=/tmp/edit.dtb of=$1 seek=512 bs=1k conv=notrunc
  rm /tmp/edit.dtb
}

function create_bad_fit() {
  N=$1
  EXPR="$2"

  echo "[+] Creating $N..."
  cp $UBOOT_DTS $OUTPUT_DIR/error/u-boot.$N.dts
  sed -i "$EXPR" $OUTPUT_DIR/error/u-boot.$N.dts
  cp $OUTPUT_DIR/flashes/$FLASH_SIGNED $OUTPUT_DIR/flashes/$INPUT_NAME.CS1.$N
  edit_dtb $OUTPUT_DIR/flashes/$INPUT_NAME.CS1.$N $OUTPUT_DIR/error/u-boot.$N.dts
  ln -sf $FLASH_SIGNED $OUTPUT_DIR/flashes/$INPUT_NAME.CS0.$N
}

# Place all error intermediate assets in ./error
mkdir -p "$OUTPUT_DIR/error"

create_bad_fit "3.31" 's/images {/images1 {/g'
create_bad_fit "3.32" 's/images {/images { }; noimages {/g'
create_bad_fit "3.33" 's/configurations {/configurations1 {/g'

# 34 is difficult, need to remove gd() from CS0

create_bad_fit "3.35" 's/keys {/keys1 {/g'
create_bad_fit "3.36" 's/data = <0xd00dfeed/data2 = <0xd00dfeed/g'
create_bad_fit "3.37.1" 's/data-position =/data2-position =/g'
create_bad_fit "3.37.2" 's/data-size =/data2-size =/g'
create_bad_fit "3.37.3" 's/data-size = <\(.*\)>;/data-size = <0xDDDDDDDD>;/g'
create_bad_fit "3.38" 's/data = <\(.*\)>;/data = <\1 \1 \1 \1 \1 \1 \1 \1\ \1 \1 \1>;/g'

# Generate keys needed for failure cases.
mkdir -p "$OUTPUT_DIR/error/kek"
openssl genrsa -F4 -out "$OUTPUT_DIR/error/kek/kek.key" 4096
openssl rsa -in "$OUTPUT_DIR/error/kek/kek.key" -pubout > "$OUTPUT_DIR/error/kek/kek.pub"
echo -e "\nCreated error-KEK (ROM key): $OUTPUT_DIR/error/kek/kek.{key,pub}\n"

mkdir -p "$OUTPUT_DIR/error/subordinate"
$SCRIPTS/fit-signsub --mkimage $MKIMAGE --keydir $OUTPUT_DIR/error/kek \
  $OUTPUT_DIR/subordinate/subordinate.dtb $OUTPUT_DIR/error/subordinate/subordinate.dtb.signed

echo "[+] Creating 4.40.1..."
$SCRIPTS/fit-sign --mkimage $MKIMAGE --kek $OUTPUT_DIR/kek/kek.dtb \
  --signed-subordinate $OUTPUT_DIR/error/subordinate/subordinate.dtb.signed \
  --keydir $OUTPUT_DIR/subordinate $OUTPUT_DIR/flashes/$FLASH_UNSIGNED \
  $OUTPUT_DIR/flashes/$INPUT_NAME.CS1.4.40.1
ln -sf $FLASH_SIGNED $OUTPUT_DIR/flashes/$INPUT_NAME.CS0.4.40.1

create_bad_fit "4.40.2" 's/key-name-hint = "kek"/key-name-hint = "not-kek"/g'
create_bad_fit "4.40.3" 's/data = <0xd00dfeed/data = <0xd00dfefd/g'
create_bad_fit "4.42.1" 's/timestamp = <\(.*\)>;/timestamp = <0x10>;/g'

BAD_HASH="0x10 0x10 0x10 0x10 0x10 0x10 0x10 0x10"
MATCH='compression = "none";\(.*\)value = <\(.*\)>;\n\t\t\t\talgo\(.*\)config'
MATCH=":a;N;\$!ba;s/${MATCH}/compression = \"none\";\\1value = "
MATCH="${MATCH}<${BAD_HASH}>;\\n\\t\\t\\t\\talgo\\3/g"
create_bad_fit "4.42.2" "$MATCH"

create_bad_fit "4.42.3" 's/key-name-hint = "subordinate"/key-name-hint = "kek"/g'
create_bad_fit "4.42.4" 's/compression = "none";/compression = "none";\n\n\t\t\thash@2 { algo = "sha256"; };/g'

echo "[+] Creating 4.43..."
cp $OUTPUT_DIR/flashes/$FLASH_SIGNED $OUTPUT_DIR/flashes/$INPUT_NAME.CS1.4.43
dd if=/dev/random of=$OUTPUT_DIR/flashes/$INPUT_NAME.CS1.4.43 bs=1 seek=540772 count=16 conv=notrunc
ln -sf $FLASH_SIGNED $OUTPUT_DIR/flashes/$INPUT_NAME.CS0.4.43
