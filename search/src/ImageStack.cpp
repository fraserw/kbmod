/*
 * ImageStack.cpp
 *
 *  Created on: Jun 22, 2017
 *      Author: kbmod-usr
 */

#include "ImageStack.h"

namespace kbmod {

ImageStack::ImageStack(std::vector<std::string> files)
{
	verbose = true;
	fileNames = files;
	resetImages();
	loadImages();
	extractImageTimes();
	setTimeOrigin();
	masterMask = RawImage(getWidth(), getHeight());
	avgTemplate = RawImage(getWidth(), getHeight());
}

ImageStack::ImageStack(std::vector<LayeredImage> imgs)
{
	verbose = true;
	images = imgs;
	extractImageTimes();
	setTimeOrigin();
	fileNames = std::vector<std::string>();
	for (LayeredImage& i : imgs) fileNames.push_back(i.getName());
	masterMask = RawImage(getWidth(), getHeight());
	avgTemplate = RawImage(getWidth(), getHeight());
}

void ImageStack::loadImages()
{

	if (fileNames.size()==0)
	{
		std::cout << "No files provided" << "\n";
	}

	// Load images from file
	for (auto& i : fileNames)
	{
		images.push_back(LayeredImage(i));
		if (verbose) std::cout << "." << std::flush;
	}
	if (verbose) std::cout << "\n";
}

void ImageStack::extractImageTimes()
{
	// Load image times
	imageTimes = std::vector<float>();
	for (auto& i : images)
	{
		imageTimes.push_back(float(i.getTime()));
	}
}

void ImageStack::setTimeOrigin()
{
	// Set beginning time to 0.0
	double initialTime = imageTimes[0];
	for (auto& t : imageTimes) t = t - initialTime;
}

std::vector<LayeredImage>& ImageStack::getImages()
{
	return images;
}

unsigned ImageStack::imgCount()
{
	return images.size();
}

std::vector<float> ImageStack::getTimes()
{
	return imageTimes;
}

void ImageStack::setTimes(std::vector<float> times)
{
	if (times.size() != imgCount())
		throw std::runtime_error("List of times provided"
				" does not match the number of images!");
	imageTimes = times;
	setTimeOrigin();
}

void ImageStack::resetImages()
{
	images = std::vector<LayeredImage>();
}

void ImageStack::convolve(PointSpreadFunc psf)
{
	for (auto& i : images) i.convolve(psf);
}

void ImageStack::saveMasterMask(std::string path)
{
	//std::cout << masterMask.getWidth() << "\n";
	//std::cout << masterMask.getHeight() << "\n";
	masterMask.saveToFile(path);
	//RawImage test(100, 100);
	//test.saveToFile(path);
}

void ImageStack::saveImages(std::string path)
{
	for (auto& i : images) i.saveLayers(path);
}

RawImage ImageStack::getMasterMask()
{
	return masterMask;
}

std::vector<RawImage> ImageStack::getSciences()
{
	std::vector<RawImage> imgs;
	for (auto i : images) imgs.push_back(i.getScience());
	return imgs;
}

std::vector<RawImage> ImageStack::getMasks()
{
	std::vector<RawImage> imgs;
	for (auto i : images) imgs.push_back(i.getMask());
	return imgs;
}

std::vector<RawImage> ImageStack::getVariances()
{
	std::vector<RawImage> imgs;
	for (auto i : images) imgs.push_back(i.getVariance());
	return imgs;
}

void ImageStack::applyMaskFlags(int flags, std::vector<int> exceptions)
{
	for (auto& i : images)
	{
		i.applyMaskFlags(flags, exceptions);
	}
}

void ImageStack::applyMasterMask(int flags, int threshold)
{
	createMasterMask(flags, threshold);
	for (auto& i : images)
	{
		i.applyMasterMask(masterMask);
	}
}

void ImageStack::applyMaskThreshold(float thresh)
{
	for (auto& i : images) i.applyMaskThreshold(thresh);
}

void ImageStack::growMask()
{
	for (auto& i : images) i.growMask();
}

void ImageStack::createMasterMask(int flags, int threshold)
{
	// Initialize masterMask to 0.0s
	float *masterM = masterMask.getDataRef();
	for (unsigned int img=0; img<images.size(); ++img)
	{
		float *imgMask = images[img].getMDataRef();
		// Count the number of times a pixel has any of the flags
		for (unsigned int pixel=0; pixel<getPPI(); ++pixel)
		{
			if ((flags & static_cast<int>(imgMask[pixel])) != 0)
				masterM[pixel]++;
		}
	}

	// Set all pixels below threshold to 0 and all above to 1
	float fThreshold = static_cast<float>(threshold);
	for (unsigned int p=0; p<getPPI(); ++p)
	{
		masterM[p] = masterM[p] < fThreshold ? 0.0 : 1.0;
	}

}

void ImageStack::simpleDifference()
{
	createTemplate();
	for (auto& i : images) i.subtractTemplate(avgTemplate);
}

void ImageStack::createTemplate()
{
	assert(avgTemplate.getWidth() == getWidth() &&
		   avgTemplate.getHeight() == getHeight() );
	float *templatePix = avgTemplate.getDataRef();
	for (auto& i : images)
	{
		float *imgPix = i.getSDataRef();
		for (unsigned p=0; p < getPPI(); ++p)
			templatePix[p] += imgPix[p];
	}

	for (unsigned p=0; p<getPPI(); ++p)
		templatePix[p] /= static_cast<float>(imgCount());
}


} /* namespace kbmod */

