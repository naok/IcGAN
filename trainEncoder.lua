-- This file reads the dataset generated by generateEncoderDataset.lua and
-- trains an encoder net that learns to map an image X to a noise vector Z (encoder Z, type Z)
-- or an encoded that maps an image X to an attribute vector Y (encoder Y, type Y).

require 'image'
require 'nn'
require 'optim'
torch.setdefaulttensortype('torch.FloatTensor')

local function getParameters()

  opt = {}
  
  -- Type of encoder must be passed as argument to decide what kind of
  -- encoder will be trained (encoder Z [type Z] or encoder Y [type Y])
  opt.type = os.getenv('type')
  
  assert(opt.type, "Parameter 'type' not specified. It is necessary to set the encoder type: 'Z' or 'Y'.\nExample: type=Z th trainEncoder.lua")
  assert(string.upper(opt.type)=='Z' or string.upper(opt.type)=='Y',"Parameter 'type' must be 'Z' (encoder Z) or 'Y' (encoder Y).")
  
  -- Load parameters from config file
  if string.upper(opt.type)=='Z' then
      assert(loadfile("cfg/mainConfig.lua"))(1)
  else
      assert(loadfile("cfg/mainConfig.lua"))(2)
  end
  
  -- one-line argument parser. Parses environment variables to override the defaults
  for k,v in pairs(opt) do opt[k] = tonumber(os.getenv(k)) or os.getenv(k) or opt[k] end
  print(opt)
  
  if opt.display then display = require 'display' end
  
  return opt
end

local function readDatasetZ(path)
-- There's expected to find in path a file named groundtruth.dmp
-- which contains the image paths / image tensors and Z and Y input vectors.
    local X
    local data = torch.load(path..'groundtruth.dmp')
    
    local Z = data.Z
    
    if data.storeAsTensor then
        X = data.X 
        assert(Z:size(1)==X:size(1), "groundtruth.dmp is corrupted, number of images and Z vectors is not equal. Create the dataset again.")
    else
        assert(Z:size(1)==#data.imNames, "groundtruth.dmp is corrupted, number of images and Z vectors is not equal. Create the dataset again.")
        
        -- Load images
        local tmp = image.load(data.relativePath..data.imNames[1])
        X = torch.Tensor(#data.imNames, data.imSize[1], data.imSize[2], data.imSize[3])
        X[{{1}}] = tmp
        
        for i=2,#data.imNames do
            X[{{i}}] = image.load(data.relativePath..data.imNames[i])
        end
    end

    return X, Z
end

local function readDatasetY(path)
-- There's expected to find in path a file named images.dmp and imLabels.dmp
-- which contains the images X and attribute vectors Y.
-- images.dmp is obtained through data/preprocess_celebA.lua
-- imLabels.dmp is obtained through trainGAN.lua via data/donkey_celebA.lua

    print('Loading images X from '..path..'images.dmp')
    local X = torch.load(path..'images.dmp')
    print(('Done. Loaded %.2f GB (%d images).'):format((4*X:size(1)*X:size(2)*X:size(3)*X:size(4))/2^30, X:size(1)))
    X:mul(2):add(-1) -- make it [0, 1] -> [-1, 1]
    
    print('Loading attributes Y from '..path..'imLabels.dmp')
    local Y = torch.load(path..'imLabels.dmp')
    print(('Done. Loaded %d attributes'):format(Y:size(1)))
    
    return X, Y
end

local function splitTrainTest(x, y, split)
    local xTrain, yTrain, xTest, yTest
    
    local nSamples = x:size(1)
    local splitInd = torch.floor(split*nSamples)
    
    xTrain = x[{{1,splitInd}}]
    yTrain = y[{{1,splitInd}}]
    
    xTest = x[{{splitInd+1,nSamples}}]
    yTest = y[{{splitInd+1,nSamples}}]
    
    return xTrain, yTrain, xTest, yTest
end

local function getEncoder(inputSize, nFiltersBase, outputSize, nConvLayers, FCsz)
  -- Encoder architecture based on Autoencoding beyond pixels using a learned similarity metric (VAE/GAN hybrid)
  
    
    
    local encoder = nn.Sequential()
    -- Assuming nFiltersBase = 64, nConvLayers = 3
    -- 1st Conv layer: 5×5 64 conv. ↓, BNorm, ReLU
    --           Data: 32x32 -> 16x16
    encoder:add(nn.SpatialConvolution(inputSize[1], nFiltersBase, 5, 5, 2, 2, 2, 2))
    encoder:add(nn.SpatialBatchNormalization(nFiltersBase))
    encoder:add(nn.ReLU(true))
   
    -- 2nd Conv layer: 5×5 128 conv. ↓, BNorm, ReLU
    --           Data: 16x16 -> 8x8
    -- 3rd Conv layer: 5×5 256 conv. ↓, BNorm, ReLU
    --           Data: 8x8 -> 4x4
    local nFilters = nFiltersBase
    for j=2,nConvLayers do
        encoder:add(nn.SpatialConvolution(nFilters, nFilters*2, 5, 5, 2, 2, 2, 2))
        encoder:add(nn.SpatialBatchNormalization(nFilters*2))
        encoder:add(nn.ReLU(true))
        nFilters = nFilters * 2
    end
    
     -- 4th FC layer: 2048 fully-connected
    --         Data: 4x4 -> 16
    encoder:add(nn.View(-1):setNumInputDims(3)) -- reshape data to 2d tensor (samples x the rest)
    -- Assuming squared images and conv layers configuration (kernel, stride and padding) is not changed:
    --nFilterFC = (imageSize/2^nConvLayers)²*nFiltersLastConvNet
    local inputFilterFC = (inputSize[2]/2^nConvLayers)^2*nFilters
    
    if FCsz == nil then FCsz = inputFilterFC end
    
    encoder:add(nn.Linear(inputFilterFC, FCsz)) 
    encoder:add(nn.BatchNormalization(FCsz))
    encoder:add(nn.ReLU(true))

    encoder:add(nn.Linear(FCsz, outputSize))

    local criterion = nn.MSECriterion()
    
    return encoder, criterion
end

local function assignBatches(batchX, batchY, x, y, batch, batchSize, shuffle)
    
    data_tm:reset(); data_tm:resume()

    batchX:copy(x:index(1, shuffle[{{batch,batch+batchSize-1}}]:long()))
    batchY:copy(y:index(1, shuffle[{{batch,batch+batchSize-1}}]:long()))
    
    data_tm:stop()
    
    return batchX, batchY
end

local function displayConfig(disp, title)
    -- initialize error display configuration
    local errorData, errorDispConfig
    if disp then
        errorData = {}
        errorDispConfig =
          {
            title = 'Encoder error - ' .. title,
            win = 1,
            labels = {'Epoch', 'Train error', 'Test error'},
            ylabel = "Error",
            legend='always'
          }
    end
    return errorData, errorDispConfig
end

function main()

  local opt = getParameters()
  print(opt)
  
  -- Set timers
  local epoch_tm = torch.Timer()
  local tm = torch.Timer()
  data_tm = torch.Timer()

  -- Read dataset
  local X, Y
  if string.upper(opt.type)=='Z' then
      X, Y = readDatasetZ(opt.datasetPath)
  else 
      X, Y = readDatasetY(opt.datasetPath)
  end
  
  -- Split train and test
  local xTrain, yTrain, xTest, yTest
  -- z --> contain Z vectors    y --> contain Y vectors
  xTrain, yTrain, xTest, yTest = splitTrainTest(X, Y, opt.split)

  -- X: #samples x im3 x im2 x im1
  -- Z: #samples x 100 x 1 x 1 
  -- Y: #samples x ny
  
  -- Set network architecture
  local encoder, criterion = getEncoder(xTrain[1]:size(), opt.nf, yTrain:size(2), opt.nConvLayers, opt.FCsz)
 
  -- Initialize batches
  local batchX = torch.Tensor(opt.batchSize, xTrain:size(2), xTrain:size(3), xTrain:size(4))
  local batchZ = torch.Tensor(opt.batchSize, yTrain:size(2))
  
  -- Copy variables to GPU
  if opt.gpu > 0 then
     require 'cunn'
     cutorch.setDevice(opt.gpu)
     batchX = batchX:cuda();  batchZ = batchZ:cuda();
     
     if pcall(require, 'cudnn') then
        require 'cudnn'
        cudnn.benchmark = true
        cudnn.convert(encoder, cudnn)
     end
     
     encoder:cuda()
     criterion:cuda()
  end
  
  local params, gradParams = encoder:getParameters() -- This has to be performed always after the cuda call
  
  -- Define optim (general optimizer)
  local errorTrain
  local errorTest
  local function optimFunction(params) -- This function needs to be declared here to avoid using global variables.
      -- reset gradients (gradients are always accumulated, to accommodat batch methods)
      gradParams:zero()
      
      local outputs = encoder:forward(batchX)
      errorTrain = criterion:forward(outputs, batchZ)
      local dloss_doutput = criterion:backward(outputs, batchZ)
      encoder:backward(batchX, dloss_doutput)
      
      return errorTrain, gradParams
  end
  
  local optimState = {
     learningRate = opt.lr,
     beta1 = opt.beta1,
  }
  
  local nTrainSamples = xTrain:size(1)
  local nTestSamples = xTest:size(1)
  
  -- Initialize display configuration (if enabled)
  local errorData, errorDispConfig = displayConfig(opt.display, opt.name)
  paths.mkdir(opt.outputPath)
  
  -- Train network
  local batchIterations = 0 -- for display purposes only
  for epoch = 1, opt.nEpochs do
      epoch_tm:reset()
      local shuffle = torch.randperm(nTrainSamples)
      for batch = 1, nTrainSamples-opt.batchSize+1, opt.batchSize  do
          tm:reset()
          
          batchX, batchZ = assignBatches(batchX, batchZ, xTrain, yTrain, batch, opt.batchSize, shuffle)
          
          if opt.display == 2 and batchIterations % 20 == 0 then
              display.image(image.toDisplayTensor(batchX,0,torch.round(math.sqrt(opt.batchSize))), {win=2, title='Train mini-batch'})
          end
          
          -- Update network
          optim.adam(optimFunction, params, optimState)
          
          -- Display train and test error
          if opt.display and batchIterations % 20 == 0 then
              -- Test error
              batchX, batchZ = assignBatches(batchX, batchZ, xTest, yTest, torch.random(1,nTestSamples-opt.batchSize+1), opt.batchSize, torch.randperm(nTestSamples))
              
              local outputs = encoder:forward(batchX)
              errorTest = criterion:forward(outputs, batchZ)
              table.insert(errorData,
              {
                batchIterations/math.ceil(nTrainSamples / opt.batchSize), -- x-axis
                errorTrain, -- y-axis for label1
                errorTest   -- y-axis for label2
              })
              display.plot(errorData, errorDispConfig)
              if opt.display == 2 then
                  display.image(image.toDisplayTensor(batchX,0,torch.round(math.sqrt(opt.batchSize))), {win=3, title='Test mini-batch'})
              end
          end
          
          -- Verbose
          if ((batch-1) / opt.batchSize) % 1 == 0 then
             print(('Epoch: [%d][%4d / %4d]  Error (train): %.4f  Error (test): %.4f  '
                       .. '  Time: %.3f s  Data time: %.3f s'):format(
                     epoch, ((batch-1) / opt.batchSize),
                     math.ceil(nTrainSamples / opt.batchSize),
                     errorTrain and errorTrain or -1,
                     errorTest and errorTest or -1,
                     tm:time().real, data_tm:time().real))
         end
         batchIterations = batchIterations + 1
      end
      print(('End of epoch %d / %d \t Time Taken: %.3f s'):format(
            epoch, opt.nEpochs, epoch_tm:time().real))
            
      -- Store network
      torch.save(opt.outputPath .. opt.name .. '_' .. epoch .. 'epochs.t7', encoder:clearState())
      torch.save('checkpoints/' .. opt.name .. '_error.t7', errorData)
  end
  
end

main()