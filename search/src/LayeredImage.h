/*
 * LayeredImage.h
 *
 *  Created on: Jul 11, 2017
 *      Author: kbmod-usr
 */

#ifndef LAYEREDIMAGE_H_
#define LAYEREDIMAGE_H_

#include <vector>
#include <fitsio.h>
#include <iostream>
#include <string>
#include <random>
#include <assert.h>
#include <stdexcept>
#include "RawImage.h"
#include "common.h"

namespace kbmod {

class LayeredImage : public ImageBase {
public:
	LayeredImage(std::string path);
	LayeredImage(std::string name, int w, int h,
		float noiseStDev, float pixelVariance, double time);
	void applyMaskFlags(int flag, std::vector<int> exceptions);
	void applyMasterMask(RawImage masterMask);
	void applyMaskThreshold(float thresh);
	void subtractTemplate(RawImage subTemplate);
	void addObject(float x, float y, float flux, PointSpreadFunc psf);
	void maskObject(float x, float y, PointSpreadFunc psf);
	void growMask();
	void saveLayers(std::string path);
	void saveSci(std::string path);
 	void saveMask(std::string path);
	void saveVar(std::string path);
	void setScience(RawImage& im);
	void setMask(RawImage& im);
	void setVariance(RawImage& im);
	RawImage& getScience();
	RawImage& getMask();
	RawImage& getVariance();
	float* getSDataRef(); // Get pointer to science pixels
	float* getVDataRef(); // Get pointer to variance pixels
	float* getMDataRef(); // Get pointer to mask pixels
	//pybind11::array_t<float> sciToNumpy();
	virtual void convolve(PointSpreadFunc psf) override;
	RawImage poolScience() { return science.pool(POOL_MAX); }
	RawImage poolVariance() { return variance.pool(POOL_MIN); }
	std::string getName() { return fileName; }
	unsigned getWidth() override { return width; }
	unsigned getHeight() override { return height; }
	long* getDimensions() override { return &dimensions[0]; }
	unsigned getPPI() override { return pixelsPerImage; }
	double getTime();
	virtual ~LayeredImage() {};

private:
	void readHeader();
	void loadLayers();
	void readFitsImg(const char *name, float *target);
	void checkDims(RawImage& im);
	std::string filePath;
	std::string fileName;
	std::string pathName;
	unsigned width;
	unsigned height;
	long dimensions[2];
	unsigned pixelsPerImage;
	double captureTime;
	RawImage science;
	RawImage mask;
	RawImage variance;

};

} /* namespace kbmod */

#endif /* LAYEREDIMAGE_H_ */
