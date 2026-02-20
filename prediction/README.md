# Avalanche prediction with Snowpack and MeteoIO

## How it works

## Pipeline

fetch data from IMIS (not done yet) -> convert json to smet file (in `inputs/`) -> run Snowpack with MeteoIO -> extract features from Snowpack output(in `outputs/`) -> use model -> predict avalanche danger level

**What is missing:** fetching data from IMIS, convert somehow the station .sno data and try to understand what is a .sno file (for now i undertsand that it maps the topography of the area and the snowpack layers ?).

**What to improve:** extract more features from the Snowpack output(.pro file), try to understand better the model used in the paper and maybe try to implement it in a more efficient way (for now i just implemented a simple feedforward neural network with 3 hidden layers and relu activation function).

### Neural network Model

The neural network training and config can be experimented in the `model.ipynb` notebook. The actual model used for the pipeline is in the `train_model.py` script. The model is trained with info from this paper: https://nhess.copernicus.org/articles/23/2523/2023/nhess-23-2523-2023.pdf

## Install SNOWPACK and dependencies

The Snowpack releases that are found in the [Downloads](https://code.wsl.ch/snow-models/snowpack/-/releases) bundle MeteoIO and Snowpack but NOT [Inishell](https://code.wsl.ch/snow-models/inishell/-/releases) that has to be downloaded separately. They are available for Linux, Windows and osX and contain an HTML documentation (either in the start menu or in the share sub-folder of the installation directory).

Inishell is used to configure Snowpack and MeteoIO. It is a graphical user interface that allows to create the configuration files for Snowpack and MeteoIO.