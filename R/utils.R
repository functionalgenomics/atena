## private function .checkPhenoData()

#' @importFrom S4Vectors nrow rownames
.checkPhenodata <- function(pdata, nr) {
  if (!is.null(pdata)) {
    if (nrow(pdata) != nr)
      stop("number of rows in 'phenodata' is different than the number of input BAM files in the input parameter object 'x'.")
    if (is.null(rownames(pdata)))
      stop("'phenodata' has no row names.")
  }
}

## private function .createColumnData()

#' @importFrom S4Vectors DataFrame
.createColumnData <- function(m, pdata) {
  colData <- DataFrame(row.names=gsub(".bam$", "", colnames(m)))
  if (!is.null(pdata))
    colData <- pdata

  colData
}

## private function .checkBamFileListArgs()
## adapted from GenomicAlignments/R/summarizeOverlaps-methods.R

#' @importFrom Rsamtools BamFileList asMates asMates<-
.checkBamFileListArgs <- function(bfl, singleEnd, fragments) {
  if (missing(bfl) || !class(bfl) %in% c("character", "BamFileList"))
    stop("argument 'bfl' should be either a string character vector of BAM file names or a 'BamFileList' object")

  if (is.character(bfl)) {
    mask <- sapply(bfl, file.exists)
    if (any(!mask))
      stop(sprintf("The following input BAM files cannot be found:\n%s",
                   paste(paste("  ", bfl[!mask]), collapse="\n")))
  }

  if (!is(bfl, "BamFileList"))
    bfl <- BamFileList(bfl, asMates=!singleEnd)

  if (singleEnd) {
    if (all(isTRUE(asMates(bfl))))
      stop("cannot specify both 'singleEnd=TRUE' and 'asMates=TRUE'")
    if (fragments)
      stop("when 'fragments=TRUE', 'singleEnd' should be FALSE")
  } else
    asMates(bfl) <- TRUE

  bfl
}

## private function .checkBamReadMapper()
## extracts the name of the read mapper software from one or more BAM files
## parameters: bamfiles - BAM file names

#' @importFrom Rsamtools scanBamHeader
.checkBamReadMapper <- function(bamfiles) {
  if (missing(bamfiles) || !"character" %in% class(bamfiles))
    stop("argument 'bamfiles' should be a string character vector of BAM file names")

  mask <- sapply(bamfiles, file.exists)
  if (any(!mask))
    stop(sprintf("The following input BAM files cannot be found:\n%s",
                 paste(paste("  ", bamfiles[!mask]), collapse="\n")))

  hdr <- scanBamHeader(bamfiles)
  readaligner <- sapply(hdr, function(x) {
                          ra <- NA_character_
                          if (!is.null(x$text[["@PG"]])) {
                            pgstr <- x$text[["@PG"]]
                            mt <- gregexpr("^PN:", pgstr)
                            wh <- which(sapply(mt, function(x) x!=-1))
                            ra <- substr(pgstr[[wh]],
                                         attr(mt[[wh]], "match.length")+1,
                                         100000L)
                          }
                          tolower(ra)
                 })
  readaligner <- readaligner[!duplicated(readaligner)]
  readaligner <- as.vector(readaligner[!is.na(readaligner)])
  if (length(readaligner) == 0)
    warning("no read aligner software information in BAM files.")
  if (any(readaligner[1] != readaligner))
    warning(sprintf("different read aligner information in BAM files. Assuming %s",
                    readaligner[1]))

  readaligner[1]
}

## private function .processFeatures()
## builds a single 'GRanges' object from input TE and gene features.
## parameters: teFeatures - a 'GRanges' or 'GRangesList' object with
##                          TE annotations
##             teFeaturesobjname - the name of 'teFeatures'
##             geneFeatures - a 'GRanges' or 'GRangesList' object with
##                            gene annotations
##             geneFeaturesobjname - the name of 'geneFeatures'
##             aggregateby - names of metadata columns in 'teFeatures'
##                           to be used later for aggregating estimated
##                           counts.

#' @importFrom S4Vectors mcols Rle DataFrame
#' @importFrom GenomeInfoDb seqlevels<- seqlevels
.processFeatures <- function(teFeatures, teFeaturesobjname, geneFeatures,
                             geneFeaturesobjname, aggregateby, aggregateexons) {

  if (missing(teFeatures))
    stop("missing 'teFeatures' argument.")

  if (!exists(teFeaturesobjname))
    stop(sprintf("input TE features object '%s' is not defined.",
                 teFeaturesobjname))

  if (!is(teFeatures, "GRanges") && !is(teFeatures, "GRangesList"))
    stop(sprintf("TE features object '%s' should be either a 'GRanges' or a 'GRangesList' object.",
                 teFeaturesobjname))

  if (length(aggregateby) > 0)
    if (any(!aggregateby %in% colnames(mcols(teFeatures))))
        stop(sprintf("%s not in metadata columns of the TE features object.",
             paste(aggregateby[!aggregateby %in% colnames(mcols(teFeatures))])))

  if (is.null(names(teFeatures)) && length(aggregateby) == 0)
    stop(sprintf("the TE features object '%s' has no names and no aggregation metadata columns have been specified.",
                 teFeaturesobjname))

  features <- teFeatures
  if (is(teFeatures, "GRangesList"))
    features <- unlist(teFeatures)

  if (!all(is.na(geneFeatures))) {
    geneFeaturesobjname <- deparse(substitute(geneFeatures))
    if (!is(geneFeatures, "GRanges") && !is(geneFeatures, "GRangesList"))
      stop(sprintf("gene features object '%s' should be either a 'GRanges' or a 'GRangesList' object.",
                   geneFeaturesobjname))
    if (any(names(geneFeatures) %in% names(teFeatures)))
      stop("gene features have some common identifiers with the TE features.")

    if (length(geneFeatures) == 0)
      stop(sprintf("gene features object '%s' is empty.", geneFeaturesobjname))

    if (is(geneFeatures, "GRangesList"))
      geneFeatures <- unlist(geneFeatures)
    
    
    slev <- unique(c(seqlevels(teFeatures), seqlevels(geneFeatures)))
    seqlevels(teFeatures) <- slev
    seqlevels(geneFeatures) <- slev
    features <- c(teFeatures, geneFeatures)
    temask <- Rle(rep(FALSE, length(teFeatures) + length(geneFeatures)))
    temask[1:length(teFeatures)] <- TRUE
    features$isTE <- temask
  } else {
    features$isTE <- rep(TRUE, length(features))
  }
  
  ## Aggregating exons into genes for TEtranscripts gene annotations
  iste <- as.vector(features$isTE)
  if (!all(is.na(geneFeatures))) {
    if (aggregateexons & !all(iste) & !is.null(mcols(geneFeatures)$type)) {
      iste <- aggregate(iste, by = list(names(features)), unique)
      features <- .groupGeneExons(features)
      mtname <- match(names(features), iste$Group.1)
      iste <- iste[mtname,"x"]
    }
  }
  attr(features, "isTE") <- DataFrame("isTE" = iste)
  
  features
}


## private function .groupGeneExons()
## groups exons from the same gene creating a 'GRangesList' object
.groupGeneExons <- function(features) {
  if (!any(mcols(features)$type == "exon")) {
    stop(".groupGeneExons: no elements with value 'exon' in 'type' column of the metadata of the 'GRanges' or 'GRangesList' object with gene annotations.")
  }
  featuressplit <- split(x = features, f = names(features))
  featuressplit
}


## private function .consolidateFeatures()
## builds a 'GRanges' or 'GRangesList' object
## grouping TE features, if necessary, and
## adding gene features, if available.
## parameters: x - TEtranscriptsParam object
##             fnames - feature names vector to which
##                      consolidated features should match

#' @importFrom methods is
#' @importFrom S4Vectors split
#' @importFrom GenomicRanges GRangesList
.consolidateFeatures <- function(x, fnames) {
  
  iste <- as.vector(attributes(x@features)$isTE[,1])
  teFeatures <- x@features
  if (!is.null(iste) && any(iste)) {
    teFeatures <- x@features[iste]
  }

  if (length(x@aggregateby) > 0) {
    f <- .factoraggregateby(teFeatures, x@aggregateby)
    if (is(teFeatures, "GRangesList"))
      teFeatures <- unlist(teFeatures)
    teFeatures <- split(teFeatures, f)
  }

  features <- teFeatures
  if (!is.null(iste) && any(!iste)) {
    geneFeatures <- x@features[!iste]
    # if (is(features, "GRangesList")) ## otherwise is a GRanges object
    #   geneFeatures <- split(geneFeatures, names(geneFeatures))
    features <- c(features, geneFeatures)
  }

  stopifnot(length(features) == length(fnames)) ## QC
  features <- features[match(fnames, names(features))]

  features
}


# .consolidateFeatures <- function(x, fnames) {
# 
#   teFeatures <- x@features
#   if (!is.null(x@features$isTE) && any(x@features$isTE)) {
#     teFeatures <- x@features[x@features$isTE]
#   }
#   
#   if (length(x@aggregateby) > 0) {
#     f <- .factoraggregateby(teFeatures, x@aggregateby)
#     teFeatures <- split(teFeatures, f)
#   }
#   
#   features <- teFeatures
#   if (!is.null(x@features$isTE) && any(!x@features$isTE)) {
#     geneFeatures <- x@features[!x@features$isTE]
#     if (is(features, "GRangesList")) ## otherwise is a GRanges object
#       geneFeatures <- split(geneFeatures, names(geneFeatures))
#     features <- c(features, geneFeatures)
#   }
#   
#   stopifnot(length(features) == length(fnames)) ## QC
#   features <- features[match(fnames, names(features))]
#   
#   features
# }

## private function .factoraggregateby()
## builds a factor with as many values as the
## length of the input annotations in 'ann', where
## every value is made by pasting the columns in
## 'aggby' separated by ':'.
## parameters: ann - GRanges object with annotations
##             aggby - names of metadata columns in 'ann'
##                     to be pasted together

#' @importFrom GenomicRanges mcols
f <- .factoraggregateby <- function(ann, aggby) {
  if (is(ann,"GRangesList")) {
    ann <- unlist(ann)
  }
  stopifnot(all(aggby %in% colnames(mcols(ann)))) ## QC
  if (length(aggby) == 1) {
    f <- mcols(ann)[, aggby]
  } else {
    spfstr <- paste(rep("%s", length(aggby)), collapse=":")
    f <- do.call("sprintf", c(spfstr, as.list(mcols(ann)[, aggby])))
  }
  f
}

## private function .getReadFunction()
## borrowed from GenomicAlignments/R/summarizeOverlaps-methods.R
.getReadFunction <- function(singleEnd, fragments) {
  if (singleEnd) {
    FUN <- readGAlignments
  } else {
    if (fragments)
      FUN <- readGAlignmentsList
    else
      FUN <- readGAlignmentPairs
  }
  
  FUN
}

## private function .appendHits()
## appends the second Hits object to the end of the first one
## assuming they have identical right nodes

#' @importFrom S4Vectors nLnode nRnode isSorted from to Hits
.appendHits <- function(hits1, hits2) {
  stopifnot(nRnode(hits1) == nRnode(hits2))
  stopifnot(isSorted(from(hits1)) == isSorted(from(hits2)))
  hits <- c(Hits(from=from(hits1), to=to(hits1),
                 nLnode=nLnode(hits1)+nLnode(hits2),
                 nRnode=nRnode(hits1), sort.by.query=isSorted(from(hits1))),
            Hits(from=from(hits2)+nLnode(hits1), to=to(hits2),
                 nLnode=nLnode(hits1)+nLnode(hits2),
                 nRnode=nRnode(hits2), sort.by.query=isSorted(from(hits2))))
  hits
}
