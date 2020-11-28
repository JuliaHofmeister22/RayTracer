// pass in list of doubles instead of pointers
// write out sequence header once, run through everything, and THEN close the sequence

// class bitWriter go from struct to before jo_DCT


import 'dart:math';
import 'dart:typed_data';

import 'image.dart';
import 'maths.dart';
import 'fileloader.dart';

// original: https://github.com/yui0/slibs/blob/master/jo_mpeg.h
// modified: Dr. Jon Denning
// Only supports 24, 25, 30, 50, or 60 fps

// Huffman tables for RLE encoding
// https://en.wikipedia.org/wiki/MPEG-1#Entropy_coding


const s_jo_HTDC_Y = [[4,3], [0,2], [1,2], [5,3], [ 6,3], [14,4], [30,5], [ 62,6], [126,7]];
const s_jo_HTDC_C = [[0,2], [1,2], [2,2], [6,3], [14,4], [30,5], [62,6], [126,7], [254,8]];
const s_jo_HTAC = [

    [[6,3],[8,5],[10,6],[12,8],[76,9],[66,9],[20,11],[58,13],[48,13],[38,13],[32,13],[52,14],[50,14],[48,14],[46,14],[62,15],[62,15],[58,15],[56,15],[54,15],[52,15],[50,15],[48,15],[46,15],[44,15],[42,15],[40,15],[38,15],[36,15],[34,15],[32,15],[48,16],[46,16],[44,16],[42,16],[40,16],[38,16],[36,16],[34,16],[32,16],],

    [[6,4],[12,7],[74,9],[24,11],[54,13],[44,14],[42,14],[62,16],[60,16],[58,16],[56,16],[54,16],[52,16],[50,16],[38,17],[36,17],[34,17],[32,17]],

    [[10,5],[8,8],[22,11],[40,13],[40,14]],

    [[14,6],[72,9],[56,13],[38,14]],

    [[12,6],[30,11],[36,13]],  [[14,7],[18,11],[36,14]],  [[10,7],[60,13],[40,17]],

    [[8,7],[42,13]],  [[14,8],[34,13]],  [[10,8],[34,14]],  [[78,9],[32,14]],  [[70,9],[52,17]],  [[68,9],[50,17]],  [[64,9],[48,17]],  [[28,11],[46,17]],  [[26,11],[44,17]],  [[16,11],[42,17]],

    [[62,13]], [[52,13]], [[50,13]], [[46,13]], [[44,13]], [[62,14]], [[60,14]], [[58,14]], [[56,14]], [[54,14]], [[62,17]], [[60,17]], [[58,17]], [[56,17]], [[54,17]],

];

const s_jo_quantTbl = [

    0.015625, 0.005632, 0.005035, 0.004832, 0.004808, 0.005892, 0.007964, 0.013325,

    0.005632, 0.004061, 0.003135, 0.003193, 0.003338, 0.003955, 0.004898, 0.008828,

    0.005035, 0.003135, 0.002816, 0.003013, 0.003299, 0.003581, 0.005199, 0.009125,

    0.004832, 0.003484, 0.003129, 0.003348, 0.003666, 0.003979, 0.005309, 0.009632,

    0.005682, 0.003466, 0.003543, 0.003666, 0.003906, 0.004546, 0.005774, 0.009439,

    0.006119, 0.004248, 0.004199, 0.004228, 0.004546, 0.005062, 0.006124, 0.009942,

    0.008883, 0.006167, 0.006096, 0.005777, 0.006078, 0.006391, 0.007621, 0.012133,

    0.016780, 0.011263, 0.009907, 0.010139, 0.009849, 0.010297, 0.012133, 0.019785,

];

// see http://www.bretl.com/mpeghtml/zigzag.HTM

const s_jo_ZigZag = [

     0,  1,  5,  6, 14, 15, 27, 28,

     2,  4,  7, 13, 16, 26, 29, 42,

     3,  8, 12, 17, 25, 30, 41, 43,

     9, 11, 18, 24, 31, 40, 44, 53,

    10, 19, 23, 32, 39, 45, 52, 54,

    20, 22, 33, 38, 46, 51, 55, 60,

    21, 34, 37, 47, 50, 56, 59, 61,

    35, 36, 48, 49, 57, 58, 62, 63,

];


// wrapper for put1b, put4b, put8b, data.bufferBits

class BitWriter {

    List _data = [];
    int _bitbuf = 0, _bitcnt = 0;

    Uint8List getData() {
        flushBufferedBits();
        return Uint8List.fromList(_data);
    }

    void bufferBits(int value, int count) {
        // copied from https://github.com/yui0/slibs/blob/master/jo_mpeg.h#L109
        // 3 2         1         0
        // 10987654321098765432109876543210
        // 00000000000000000000000000000000
        // 00000000a00000000000000000000000  bitcnt = 0, count = 1, 24-(0+1) = 23
        // 00000000ab0000000000000000000000  bitcnt = 1, count = 1, 24-(1+1) = 22
        // 00000000abcc00000000000000000000  bitcnt = 2, count = 2, 24-(2+2) = 20
        // 00000000abccddddd000000000000000  bitcnt = 4, count = 5, 24-(4+5) = 15
        // XXXXXXXXabccdddd                  >> 16 & 255
        // 00000000d00000000000000000000000  bitcnt = 1
        // ^       ^       ^
        // |       |       + these are 2 additional bytes for temp buffering
        // |       + this 1byte is written once >=8bits are buffered
        // + this 1byte is always 0
        // once >=8bits are buffered, the byte is written out (can repeat if >=16bits are buffered)
        // when this function returns, there will be between 0--7bits left in buffer

        value &= (1<<count) - 1;  // c++
        _bitcnt += count;
        _bitbuf |= value << (24 - _bitcnt);

        while(_bitcnt >= 8) {
            var c = (_bitbuf >> 16) & 255;
            _data.add(c);
            _bitbuf <<= 8;
            _bitcnt -= 8;
        }
    }

    void flushBufferedBits() {
        // flushes out any remaining buffered bits

        if(_bitcnt == 0) return;        // nothing currently buffered
        _data.add((_bitbuf >> 16) & 255);
        _bitbuf = 0;
        _bitcnt = 0;
    }



    void putBits(List bits) {
        // assuming bits is multiple of 8

        flushBufferedBits();

        int buf = 0;
        int count = 0;

        for(int bit in bits) {
            buf = (buf << 1) | bit;
            count += 1;
            if(count == 8) {
                put1B(buf);
                buf = 0;
                count = 0;
            }
        }
        assert(count == 0);
    }

    void put1B(int v) {
        flushBufferedBits();
        _data.add(v);
    }

    void put4B(int c0, int c1, int c2, int c3) {
        flushBufferedBits();
        _data.add(c0);
        _data.add(c1);
        _data.add(c2);
        _data.add(c3);
    }

    void put8B(int c0, int c1, int c2, int c3, int c4, int c5, int c6, int c7) {
        flushBufferedBits();
        _data.add(c0);
        _data.add(c1);
        _data.add(c2);
        _data.add(c3);
        _data.add(c4);
        _data.add(c5);
        _data.add(c6);
        _data.add(c7);
    }
}



int bitCount(int v) {
    int p = 0;
    while(v > 0) {
        p++;
        v >>= 1;
    }
    return p;
}

// performs phases to pullout the weights of signals
// result is returned by manipulating individual values directly
// descrete cosine transform

// pass in array, each indicie 
static void jo_DCT(array, d0, d1, d2, d3, d4, d5, d6, d7)
[
	var tmp0 = d0 + d7;
	var tmp7 = d0 - d7;
	var tmp1 = d1 + d6;
	var tmp6 = d1 - d6;
	var tmp2 = d2 + d5;
	var tmp5 = d2 - d5;
	var tmp3 = d3 + d4;
	var tmp4 = d3 - d4;

	// Even part
	var tmp10 = tmp0 + tmp3;	// phase 2
	var tmp13 = tmp0 - tmp3;
	var tmp11 = tmp1 + tmp2;
	var tmp12 = tmp1 - tmp2;

	d0 = tmp10 + tmp11; 		// phase 3
	d4 = tmp10 - tmp11;

	var z1 = (tmp12 + tmp13) * 0.707106781f; // c4
	d2 = tmp13 + z1; 		// phase 5
	d6 = tmp13 - z1;

	// Odd part
	tmp10 = tmp4 + tmp5; 		// phase 2
	tmp11 = tmp5 + tmp6;
	tmp12 = tmp6 + tmp7;

	// The rotator is modified from fig 4-8 to avoid extra negations.
	var z5 = (tmp10 - tmp12) * 0.382683433f; // c6
	var z2 = tmp10 * 0.541196100f + z5; // c2-c6
	var z4 = tmp12 * 1.306562965f + z5; // c2+c6
	var z3 = tmp11 * 0.707106781f; // c4

	var z11 = tmp7 + z3;		// phase 5
	var z13 = tmp7 - z3;

	d5 = z13 + z2;			// phase 6
	d3 = z13 - z2;
	d1 = z11 + z4;
	d7 = z11 - z4;

  return array; // correct? c++
]


// runlength and coding on the lengths
// bits pointer is the tool it uses for writing out individual bits and bytes for it
// takes in a single block and writes it out
static int jo_processDU(data, var A[64], const unsigned char htdc[9][2], int DC)
[
	for (int dataOff=0; dataOff<64; dataOff+=8) [
		jo_DCT(A, A[0], A[1], A[2], A[3], A[4], A[5], A[6], A[7]);
	]
	for (int dataOff=0; dataOff<8; ++dataOff) [
		jo_DCT(A, A[0], A[8], A[16], A[24], A[32], A[40], A[48], A[56]);
	]
	int Q[64];
	for (int i=0; i<64; ++i) [
		var v = A[i]*s_jo_quantTbl[i];
		Q[s_jo_ZigZag[i]] = (int)(v < 0 ? ceilf(v - 0.5f) : floorf(v + 0.5f));
	]

	DC = Q[0] - DC;
	int aDC = DC < 0 ? -DC : DC;
	int size = 0;
	int tempval = aDC;
	while (tempval) [
		size++;
		tempval >>= 1;
	]
	data.bufferBits(htdc[size][0], htdc[size][1]);
	if (DC < 0) [
		aDC ^= (1 << size) - 1;
	]
	data.bufferBits(aDC, size);

	int endpos = 63;
	for (; (endpos>0)&&(Q[endpos]==0); --endpos) [
		/* do nothing */
	]
	for (int i = 1; i <= endpos;) [
		int run = 0;
		while (Q[i]==0 && i<endpos) [
			++run;
			++i;
		]
		int AC = Q[i++];
		int aAC = AC < 0 ? -AC : AC;
		int code = 0, size = 0;
		if (run<32 && aAC<=41) [
			code = s_jo_HTAC[run][aAC-1][0];
			size = s_jo_HTAC[run][aAC-1][1];
			if (AC < 0) [
				code += 1;
			]
		]
		if (!size) [
			data.bufferBits(bits, 1, 6);
			data.bufferBits(bits, run, 6);
			if (AC < -127) [
				data.bufferBits(bits, 128, 8);
			] else if (AC > 127) [
				data.bufferBits(bits, 0, 8);
			]
			code = AC&255;  // c++?
			size = 8;
		]
		data.bufferBits(bits, code, size);
	]
	data.bufferBits(bits, 2, 2);

	return Q[0];
]


// takes in rgb image and breaks it up
int encode_mpeg(unsigned char *mem, const unsigned char *rgbx, int width, int height, int fps)
[
	unsigned char *smem = mem;
	int lastDCY = 128, lastDCCR = 128, lastDCCB = 128;
	jo_bits_t bits = [&mem];

	// Sequence Header
	put4b("\x00\x00\x01\xB3", &mem);
	// 12 bits for width, height
	put1b((width>>4)&0xFF, &mem);
	put1b(((width&0xF)<<4) | ((height>>8) & 0xF), &mem);
	put1b(height & 0xFF, &mem);
	// aspect ratio, framerate
	if (fps <= 24) [
		put1b(0x12, &mem);
	] else if (fps <= 25) [
		put1b(0x13, &mem);
	] else if (fps <= 30) [
		put1b(0x15, &mem);
	] else if (fps <= 50) [
		put1b(0x16, &mem);
	] else [
		put1b(0x18, &mem);	// 60fps
	]
	put4b("\xFF\xFF\xE0\xA0", &mem);

	put8b("\x00\x00\x01\xB8\x80\x08\x00\x40", &mem); // GOP header
	put8b("\x00\x00\x01\x00\x00\x0C\x00\x00", &mem); // PIC header
	put4b("\x00\x00\x01\x01", &mem); // Slice header
	data.bufferBits(&bits, 0x10, 6);

	for (int vblock=0; vblock<(height+15)/16; vblock++) [
		for (int hblock=0; hblock<(width+15)/16; hblock++) [
			data.bufferBits(&bits, 3, 2);

			var Y[256], CBx[256], CRx[256];
			for (int i=0; i<256; ++i) [
				int y = vblock*16+(i/16);
				int x = hblock*16+(i&15);
				x = x >= width ? width-1 : x;
				y = y >= height ? height-1 : y;
				//const unsigned char *c = rgbx + y*width*4+x*4;
				const unsigned char *c = rgbx + y*width*3+x*3;
				var r = c[0], g = c[1], b = c[2];
				Y[i] = (0.59f*r + 0.30f*g + 0.11f*b) * (219.f/255) + 16;
				CBx[i] = (-0.17f*r - 0.33f*g + 0.50f*b) * (224.f/255) + 128;
				CRx[i] = (0.50f*r - 0.42f*g - 0.08f*b) * (224.f/255) + 128;
			]

			// Downsample Cb,Cr (420 format)
			var CB[64], CR[64];
			for (int i=0; i<64; ++i) [
				int j =(i&7)*2 + (i&56)*4;
				CB[i] = (CBx[j] + CBx[j+1] + CBx[j+16] + CBx[j+17]) * 0.25f;
				CR[i] = (CRx[j] + CRx[j+1] + CRx[j+16] + CRx[j+17]) * 0.25f;
			]

			for (int k1=0; k1<2; ++k1) [
				for (int k2=0; k2<2; ++k2) [
					var block[64];
					for (int i=0; i<64; i+=8) [
						int j = (i&7)+(i&56)*2 + k1*8*16 + k2*8;
						memcpy(block+i, Y+j, 8*sizeof(Y[0]));
					]
					lastDCY = jo_processDU(&bits, block, s_jo_HTDC_Y, lastDCY);
				]
			]
			lastDCCB = jo_processDU(&bits, CB, s_jo_HTDC_C, lastDCCB);
			lastDCCR = jo_processDU(&bits, CR, s_jo_HTDC_C, lastDCCR);
		]
	]
	data.bufferBits(&bits, 0, 7);
	put4b("\x00\x00\x01\xb7", &mem); // End of Sequence
	// size is very small, safe to cast to `int`
	return (int)(mem-smem);
]

/*
#include <stdlib.h>
void jo_write_mpeg(FILE *fp, const unsigned char *rgbx, int width, int height, int fps)
[
	unsigned char *mem = (unsigned char *)malloc(width*height*3);
	//unsigned char *mem = calloc(1, width*height*3);
	int s = encode_mpeg(mem, rgbx, width, height, fps);
	fwrite(mem, s, 1, fp);
	free(mem);
]
#endif
*/

// make call to bitCount and encode_mpeg?

void saveVideo(String path, List images, int width, int height, int fps, {repeatFrames:1}) {

    var data = BitWriter();
    // encode sequence header
    for(Image image in images) {
        for(int i = 0; i < repeatFrames; i++) {
          // encode image
          data._data += encode_mpeg(i, image, width, height, fps);
        }
    }
    // encode sequence end

    // write encoded video out to file
    var fp = File(path);
    var sink = fp.openWrite();
    sink.add(data.getData());
    sink.close();
}

