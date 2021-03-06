# Internal functions -----------------------------------------------------------

pickCompProbes <- function(mSet, cellTypes = NULL, numProbes = 50,
                           compositeCellType = compositeCellType,
                           probeSelect = probeSelect) {
    .isMatrixBackedOrStop(mSet)
    splitit <- function(x) {
        split(seq_along(x), x)
    }

    p <- getBeta(mSet)
    pd <- as.data.frame(colData(mSet))
    if (!is.null(cellTypes)) {
        if (!all(cellTypes %in% pd$CellType))
            stop("elements of argument 'cellTypes' is not part of ",
                 "'mSet$CellType'")
        keep <- which(pd$CellType %in% cellTypes)
        pd <- pd[keep,]
        p <- p[,keep]
    }
    # NOTE: Make cell type a factor
    pd$CellType <- factor(pd$CellType, levels = cellTypes)
    ffComp <- rowFtests(p, pd$CellType)
    prof <- vapply(
        X = splitit(pd$CellType),
        FUN = function(j) rowMeans2(p, cols = j),
        FUN.VALUE = numeric(nrow(p)))
    r <- rowRanges(p)
    compTable <- cbind(ffComp, prof, r, abs(r[, 1] - r[, 2]))
    names(compTable)[1] <- "Fstat"
    names(compTable)[c(-2, -1, 0) + ncol(compTable)] <-
        c("low", "high", "range")
    tIndexes <- splitit(pd$CellType)
    tstatList <- lapply(tIndexes, function(i) {
        x <- rep(0,ncol(p))
        x[i] <- 1
        return(rowttests(p, factor(x)))
    })

    if (probeSelect == "any") {
        probeList <- lapply(tstatList, function(x) {
            y <- x[x[, "p.value"] < 1e-8, ]
            yAny <- y[order(abs(y[, "dm"]), decreasing = TRUE), ]
            c(rownames(yAny)[seq(numProbes * 2)])
        })
    } else {
        probeList <- lapply(tstatList, function(x) {
            y <- x[x[, "p.value"] < 1e-8, ]
            yUp <- y[order(y[, "dm"], decreasing = TRUE), ]
            yDown <- y[order(y[, "dm"], decreasing = FALSE), ]
            c(rownames(yUp)[seq_len(numProbes)],
              rownames(yDown)[seq_len(numProbes)])
        })
    }

    trainingProbes <- unique(unlist(probeList))
    p <- p[trainingProbes,]

    pMeans <- colMeans2(p)
    names(pMeans) <- pd$CellType

    form <- as.formula(
        sprintf("y ~ %s - 1", paste(levels(pd$CellType), collapse = "+")))
    phenoDF <- as.data.frame(model.matrix(~ pd$CellType - 1))
    colnames(phenoDF) <- sub("^pd\\$CellType", "", colnames(phenoDF))
    if (ncol(phenoDF) == 2) {
        # Two group solution
        X <- as.matrix(phenoDF)
        coefEsts <- t(solve(t(X) %*% X) %*% t(X) %*% t(p))
    } else {
        # > 2 groups solution
        tmp <- validationCellType(Y = p, pheno = phenoDF, modelFix = form)
        coefEsts <- tmp$coefEsts
    }

    list(
        coefEsts = coefEsts,
        compTable = compTable,
        sampleMeans = pMeans)
}



projectCellType <- function(Y, coefCellType, contrastCellType = NULL,
                            nonnegative = TRUE, lessThanOne = FALSE) {
    if (is.null(contrastCellType)) {
        Xmat <- coefCellType
    } else {
        Xmat <- tcrossprod(coefCellType, contrastCellType)
    }

    nCol <- dim(Xmat)[2]
    if (nCol == 2) {
        Dmat <- crossprod(Xmat)
        mixCoef <- t(
            apply(Y, 2, function(x) solve(Dmat, crossprod(Xmat, x))))
        colnames(mixCoef) <- colnames(Xmat)
        return(mixCoef)
    } else {
        nSubj <- dim(Y)[2]

        mixCoef <- matrix(0, nSubj, nCol)
        rownames(mixCoef) <- colnames(Y)
        colnames(mixCoef) <- colnames(Xmat)

        if (nonnegative) {
            if (lessThanOne) {
                Amat <- cbind(rep(-1, nCol), diag(nCol))
                b0vec <- c(-1, rep(0, nCol))
            } else {
                Amat <- diag(nCol)
                b0vec <- rep(0, nCol)
            }
            for (i in seq_len(nSubj)) {
                obs <- which(!is.na(Y[,i]))
                Dmat <- crossprod(Xmat[obs,])
                mixCoef[i,] <- solve.QP(
                    Dmat = Dmat,
                    dvec = crossprod(Xmat[obs,], Y[obs,i]),
                    Amat = Amat,
                    bvec = b0vec)$sol
            }
        } else {
            for (i in seq_len(nSubj)) {
                obs <- which(!is.na(Y[,i]))
                Dmat <- crossprod(Xmat[obs,])
                mixCoef[i,] <- solve(Dmat, t(Xmat[obs,]) %*% Y[obs,i])
            }
        }
        mixCoef
    }
}

validationCellType <- function(Y, pheno, modelFix, modelBatch=NULL,
                               L.forFstat = NULL, verbose = FALSE){
    N <- dim(pheno)[1]
    pheno$y <- rep(0, N)
    xTest <- model.matrix(modelFix, pheno)
    sizeModel <- dim(xTest)[2]
    M <- dim(Y)[1]

    if (is.null(L.forFstat)) {
        # NOTE: All non-intercept coefficients
        L.forFstat <- diag(sizeModel)[-1,]
        colnames(L.forFstat) <- colnames(xTest)
        rownames(L.forFstat) <- colnames(xTest)[-1]
    }

    # Initialize various containers
    sigmaResid <- sigmaIcept <- nObserved <- nClusters <- Fstat <- rep(NA, M)
    coefEsts <- matrix(NA, M, sizeModel)
    coefVcovs <- list()

    if (verbose) cat("[validationCellType] ")
    # Loop over each CpG
    for (j in seq_len(M)) {
        # Remove missing methylation values
        ii <- !is.na(Y[j, ])
        nObserved[j] <- sum(ii)
        pheno$y <- Y[j,]

        if (j %% round(M / 10) == 0 && verbose) cat(".") # Report progress

        # Try to fit a mixed model to adjust for plate
        try({
            if (!is.null(modelBatch)) {
                fit <- try(
                    lme(modelFix, random = modelBatch, data = pheno[ii, ]))
                # NOTE: If LME can't be fit, just use OLS
                OLS <- inherits(fit, "try-error")
            } else {
                OLS <- TRUE
            }

            if (OLS) {
                fit <- lm(modelFix, data = pheno[ii, ])
                fitCoef <- fit$coef
                sigmaResid[j] <- summary(fit)$sigma
                sigmaIcept[j] <- 0
                nClusters[j] <- 0
            } else {
                fitCoef <- fit$coef$fixed
                sigmaResid[j] <- fit$sigma
                sigmaIcept[j] <- sqrt(getVarCov(fit)[1])
                nClusters[j] <- length(fit$coef$random[[1]])
            }
            coefEsts[j,] <- fitCoef
            coefVcovs[[j]] <- vcov(fit)

            useCoef <- L.forFstat %*% fitCoef
            useV <- L.forFstat %*% coefVcovs[[j]] %*% t(L.forFstat)
            Fstat[j] <- (t(useCoef) %*% solve(useV, useCoef)) / sizeModel
        })
    }
    if (verbose) cat(" done\n")

    # Name the rows so that they can be easily matched to the target data set
    rownames(coefEsts) <- rownames(Y)
    colnames(coefEsts) <- names(fitCoef)
    degFree <- nObserved - nClusters - sizeModel + 1

    # Get P values corresponding to F statistics
    Pval <- 1 - pf(Fstat, sizeModel, degFree)

    list(
        coefEsts = coefEsts,
        coefVcovs = coefVcovs,
        modelFix = modelFix,
        modelBatch = modelBatch,
        sigmaIcept = sigmaIcept,
        sigmaResid = sigmaResid,
        L.forFstat = L.forFstat,
        Pval = Pval,
        orderFstat = order(-Fstat),
        Fstat = Fstat,
        nClusters = nClusters,
        nObserved = nObserved,
        degFree = degFree)
}

Bayes.estimate <- function(rgSet, counts, referencePkg, compositeCellType, 
    inferReference = "Blood", inferCellType = "Eos", minDiff = 0.028, maxDiff = 0.168, verbose = verbose){

    if (verbose) message("[estimateCellCounts] Generating ",inferReference," estimates to predict cell type ",inferCellType," in ",compositeCellType,".\n")
    cellTypes <- colnames(counts)

    referencePkg <- sub(compositeCellType, inferReference, referencePkg)
    if (!require(referencePkg, character.only = TRUE)) {
        stop(sprintf("Could not find reference data package for compositeCellType '%s' and referencePlatform '%s' (inferred package name is '%s')",
                     compositeCellType, platform, referencePkg))
    }

    data(list = referencePkg)
    referenceRGset <- get(referencePkg)

    if (!all(cellTypes %in% referenceRGset$CellType)) {
        cellTypes <- cellTypes[cellTypes %in% referenceRGset$CellType]
    }

    processMethod <- get("preprocessQuantile")
    probeSelect <- "both"

    newpd <- DataFrame(
        sampleNames = c(colnames(rgSet), colnames(referenceRGset)),
        studyIndex = rep(
            x = c("user", "reference"),
            times = c(ncol(rgSet), ncol(referenceRGset))))
    referencePd <- colData(referenceRGset)
    combinedRGset <- combineArrays(
        object1 = rgSet,
        object2 = referenceRGset,
        outType = "IlluminaHumanMethylation450k")
    colData(combinedRGset) <- newpd
    colnames(combinedRGset) <- newpd$sampleNames
    rm(referenceRGset)

    combinedMset <- processMethod(combinedRGset)
    referenceMset <- combinedMset[, combinedMset$studyIndex == "reference"]
    colData(referenceMset) <- as(referencePd, "DataFrame")
    mSet <- combinedMset[, combinedMset$studyIndex == "user"]
    colData(mSet) <- as(colData(rgSet), "DataFrame")
    rm(combinedMset)

    compData <- pickCompProbes(
        mSet = referenceMset,
        cellTypes = c(cellTypes, inferCellType), 
        compositeCellType = inferReference,
        probeSelect = probeSelect)
    coefs <- compData$coefEsts

    inferprop <- projectCellType(getBeta(mSet)[rownames(coefs), ], coefs)

    if (verbose) message("[estimateCellCounts] Performing ",inferCellType," estimation in ", compositeCellType,".\n")
    counts[counts < 0.000001] = 0.000001
    counts.logit = log(counts/(1-counts))

    inferprop[inferprop < 0.000001] = 0.000001
    inferprop.logit = log(inferprop/(1-inferprop))

    diff = inferprop.logit[,cellTypes] - counts.logit[,cellTypes]

    y = inferprop.logit[,inferCellType]
    taumaxVAR = 1/min(apply(diff, 2, var))
    tauminVAR = 1/max(apply(diff, 2, var))
    S2inv = 1/10^4
    n = dim(inferprop.logit)[1]
    max.steps = 50000
    mu = matrix(NA, nrow = n, ncol = max.steps)
    ###Sample for posterior mu
    for (i in 1:max.steps){
        v = runif(1, minDiff, maxDiff)
        sigmainv = runif(1, tauminVAR, taumaxVAR)
        mu.mean = sigmainv*(y-v)/(sigmainv+S2inv)
        mu.var = 1/(sigmainv+S2inv)
        mu[,i] = rnorm(n, mu.mean, mu.var)
    }

    EOS = apply(mu, 1, quantile, probs = 0.5)
    EOS.prop = round(exp(EOS)/(1+exp(EOS)), digit = 4)

    cell.prop = cbind(counts, Eos = EOS.prop)
    cell.prop
}


# Exported functions -----------------------------------------------------------

estimateCellCounts <- function(rgSet, compositeCellType = "Blood",
                               processMethod = "auto", probeSelect = "auto",
                               cellTypes = c("CD8T", "CD4T", "NK", "Bcell",
                                             "Mono", "Gran"),
                               referencePlatform = c(
                                   "IlluminaHumanMethylation450k",
                                   "IlluminaHumanMethylationEPIC",
                                   "IlluminaHumanMethylation27k"),
                               bayesMethod = TRUE,
                               returnAll = FALSE, meanPlot = FALSE,
                               verbose = TRUE, ...) {

    # Check inputs
    .isMatrixBackedOrStop(rgSet, "estimateCellCounts")
    .isRGOrStop(rgSet)
    rgSet <- as(rgSet, "RGChannelSet")
    referencePlatform <- match.arg(referencePlatform)
    rgPlatform <- sub(
        "IlluminaHumanMethylation",
        "",
        annotation(rgSet)[which(names(annotation(rgSet)) == "array")])
    platform <- sub("IlluminaHumanMethylation", "", referencePlatform)
    if ((compositeCellType == "CordBlood") && (!"nRBC" %in% cellTypes)) {
        message("[estimateCellCounts] Consider including 'nRBC' in argument 'cellTypes' for cord blood estimation.\n")
    }
    referencePkg <- sprintf("FlowSorted.%s.%s", compositeCellType, platform)
    subverbose <- max(as.integer(verbose) - 1L, 0L)
    if (!require(referencePkg, character.only = TRUE)) {
        stop(sprintf("Could not find reference data package for compositeCellType '%s' and referencePlatform '%s' (inferred package name is '%s')",
                     compositeCellType, platform, referencePkg))
    }
    data(list = referencePkg)
    referenceRGset <- get(referencePkg)
    if (rgPlatform != platform) {
        rgSet <- convertArray(
            object = rgSet,
            outType = referencePlatform,
            verbose = subverbose)
    }
    if (!"CellType" %in% names(colData(referenceRGset))) {
        stop(sprintf("the reference sorted dataset (in this case '%s') needs to have a phenoData column called 'CellType'"),
             names(referencePkg))
    }
    if (sum(colnames(rgSet) %in% colnames(referenceRGset)) > 0) {
        stop("the sample/column names in the user set must not be in the ",
             "reference data ")
    }
    bayesEst <- FALSE
    bayesParams <- data.frame(compositeCellType = c("CordBlood"), inferCellType = c("Eos"), inferReference = c("Blood"), minDiff = c(0.028), maxDiff = c(0.168)) #Can be modified when additional priors are estimated. 
    if (!all(cellTypes %in% referenceRGset$CellType)) {
        if(bayesMethod == TRUE){
            inferCellType <- cellTypes[!cellTypes%in%referenceRGset$CellType]
            validrow <- which(bayesParams$inferCellType %in% inferCellType)
            if (length(validrow) == 1){
                if(bayesParams$compositeCellType[validrow] %in% compositeCellType){
                    bayesEst <- TRUE
                    bayesParams <- bayesParams[validrow,]
                    validrow <- match(compositeCellType, bayesParams$compositeCellType)
                   
                    inferCellType <- as.character(with(bayesParams, inferCellType[validrow]))
                    cellTypes <- cellTypes[!cellTypes %in% inferCellType]
                    inferReference <- as.character(with(bayesParams, inferReference[validrow]))
                    minDiff <- with(bayesParams, minDiff[validrow])
                    maxDiff <-  with(bayesParams, maxDiff[validrow])
                }
            } else{
                stop("If element of argument 'cellTypes' is not part of reference phenoData columns and bayesMethod = TRUE, must specify cell type/tissue combination with known priors for Bayesian measurement error inference function. See documentation for additional details.")
            }
        } else{
            stop(paste0("all elements of argument 'cellTypes' need to be part of the reference phenoData columns 'CellType' (containg the following elements: ",
                paste(unique(referenceRGset$CellType), collapse = "', '"),") or set bayesMethod = TRUE."))
        }
    } 
    if (length(unique(cellTypes)) < 2) {
        stop("At least 2 cell types must be provided.")
    }
    if ((processMethod == "auto") &&
        (compositeCellType %in% c("Blood", "DLPFC"))) {
        processMethod <- "preprocessQuantile"
    }
    if ((processMethod == "auto") &&
        (!compositeCellType %in% c("Blood", "DLPFC"))) {
        processMethod <- "preprocessNoob"
    }
    processMethod <- get(processMethod)
    if ((probeSelect == "auto") && (compositeCellType == "CordBlood")) {
        probeSelect <- "any"
    }
    if ((probeSelect == "auto") && (compositeCellType != "CordBlood")) {
        probeSelect <- "both"
    }

    if (verbose) {
        message("[estimateCellCounts] Combining user data with reference ",
                "(flow sorted) data.\n")
    }
    newpd <- DataFrame(
        sampleNames = c(colnames(rgSet), colnames(referenceRGset)),
        studyIndex = rep(
            x = c("user", "reference"),
            times = c(ncol(rgSet), ncol(referenceRGset))))
    referencePd <- colData(referenceRGset)
    combinedRGset <- combineArrays(
        object1 = rgSet,
        object2 = referenceRGset,
        outType = "IlluminaHumanMethylation450k")
    colData(combinedRGset) <- newpd
    colnames(combinedRGset) <- newpd$sampleNames
    rm(referenceRGset)

    if (verbose) {
        message("[estimateCellCounts] Processing user and reference data ",
                "together.\n")
    }
    if (compositeCellType == "CordBlood") {
        # NOTE: Here Shan wants to discard probes that they have decided
        #       shouldn't be used, for example multi-mapping probes. This is
        #       done by only using probes with names in the comptable.
        #       This is kind of ugly, and dataset dependent.
        combinedMset <- processMethod(combinedRGset, verbose = subverbose)
        compTable <- get(paste0(referencePkg, ".compTable"))
        combinedMset <- combinedMset[
            which(rownames(combinedMset) %in% rownames(compTable)),]
    } else {
        combinedMset <- processMethod(combinedRGset)
    }
    rm(combinedRGset)

    # Extract normalized reference data
    referenceMset <- combinedMset[, combinedMset$studyIndex == "reference"]
    colData(referenceMset) <- as(referencePd, "DataFrame")
    mSet <- combinedMset[, combinedMset$studyIndex == "user"]
    colData(mSet) <- as(colData(rgSet), "DataFrame")
    rm(combinedMset)

    if (verbose) {
        message("[estimateCellCounts] Picking probes for composition ",
                "estimation.\n")
    }
    compData <- pickCompProbes(
        mSet = referenceMset,
        cellTypes = cellTypes,
        compositeCellType = compositeCellType,
        probeSelect = probeSelect)
    coefs <- compData$coefEsts
    # TODO: Shouldn't be necessary to rm() anything
    rm(referenceMset)

    if (verbose) message("[estimateCellCounts] Estimating composition.\n")
    counts <- projectCellType(getBeta(mSet)[rownames(coefs), ], coefs)
    rownames(counts) <- colnames(rgSet)

    if (bayesEst == TRUE){
        if (verbose) message("[estimateCellCounts] Estimating ",inferCellType," composition using Bayesian measurement error model.\n")
            if (!("Gran" %in% cellTypes) && inferCellType == "Eos"){
                    message("[estimateCellCounts] It is recommended for 'Gran' to be included in cellTypes argument for eosinophil estimation.\n")
            } else {
                    if (length(cellTypes) < 3){
                        warning("[estimateCellCounts] At least 3 requested cell types recommended for Bayesian measurement error model.\n")
                    }
                        counts <- Bayes.estimate(rgSet, counts, referencePkg, compositeCellType, inferReference = inferReference,
                            inferCellType = inferCellType, minDiff = minDiff, maxDiff = maxDiff, verbose = verbose)
            }
    }   

    if (meanPlot) {
        smeans <- compData$sampleMeans
        smeans <- smeans[order(names(smeans))]
        sampleMeans <- c(
            colMeans2(
                x = getBeta(mSet),
                rows = match(rownames(coefs), rownames(mSet))),
            smeans)
        sampleColors <- c(
            rep(1, ncol(mSet)),
            1 + as.numeric(factor(names(smeans))))
        plot(sampleMeans, pch = 21, bg = sampleColors)
        legend("bottomleft",
               c("blood", levels(factor(names(smeans)))),
               col = 1:7,
               pch = 15)
    }
    if (returnAll) {
        return(list(
            counts = counts,
            compTable = compData$compTable,

            normalizedData = mSet))
    } else {
        counts
    }
}
