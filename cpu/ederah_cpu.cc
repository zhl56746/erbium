#include <string>
#include <fstream>
#include <iostream>
#include <chrono>
#include <omp.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>     // parameters

#define CFG_ENGINE_NCRITERIA 22

typedef uint16_t                                operands_t;

const uint16_t C_CACHE_LINE_WIDTH = 64;
const uint16_t C_EDGES_PER_CACHE_LINE = C_CACHE_LINE_WIDTH / sizeof(uint64_t);
const uint16_t C_RAW_CRITERION_SIZE = sizeof(uint16_t);
const uint16_t CFG_ENGINE_CRITERION_WIDTH = 14;
const uint16_t CFG_WEIGHT_WIDTH           = 20;
const uint16_t CFG_MEM_ADDR_WIDTH         = 15;  // ceil(log2(n_bram_edges_max));

const uint64_t MASK_WEIGHT     = 0xFFFFF;
const uint64_t MASK_POINTER    = 0x7FFF;
const uint64_t MASK_OPERAND_B  = 0x3FFF; // depends on CFG_ENGINE_CRITERION_WIDTH
const uint64_t MASK_OPERAND_A  = 0x3FFF; // depends on CFG_ENGINE_CRITERION_WIDTH
const uint64_t SHIFT_LAST      = CFG_WEIGHT_WIDTH+CFG_MEM_ADDR_WIDTH+2*CFG_ENGINE_CRITERION_WIDTH;
const uint64_t SHIFT_WEIGHT    = CFG_MEM_ADDR_WIDTH+2*CFG_ENGINE_CRITERION_WIDTH;
const uint64_t SHIFT_POINTER   = 2*CFG_ENGINE_CRITERION_WIDTH;
const uint64_t SHIFT_OPERAND_B = CFG_ENGINE_CRITERION_WIDTH;
const uint64_t SHIFT_OPERAND_A = 0;

enum MatchStructureType {STRCT_SIMPLE, STRCT_PAIR};
enum MatchPairFunction {FNCTR_PAIR_NOP, FNCTR_PAIR_AND, FNCTR_PAIR_OR, FNCTR_PAIR_XOR, FNCTR_PAIR_NAND, FNCTR_PAIR_NOR};
enum MatchSimpFunction {FNCTR_SIMP_NOP, FNCTR_SIMP_EQU, FNCTR_SIMP_NEQ, FNCTR_SIMP_GRT, FNCTR_SIMP_GEQ, FNCTR_SIMP_LES, FNCTR_SIMP_LEQ};
enum MatchModeType {MODE_STRICT_MATCH, MODE_FULL_ITERATION};

const uint32_t WEIGHTS[CFG_ENGINE_NCRITERIA] = {
    0, 0, 512, 524288, 256, 262144, 65536, 64, 1, 128, 131072, 16, 16384, 2, 4, 4096, 2048, 32768,
    32, 0, 8192, 8
};

const MatchStructureType STRUCT_TYPE[CFG_ENGINE_NCRITERIA] = {
    STRCT_SIMPLE, STRCT_SIMPLE, STRCT_SIMPLE, STRCT_SIMPLE, STRCT_PAIR, STRCT_PAIR, STRCT_SIMPLE,
    STRCT_SIMPLE, STRCT_PAIR, STRCT_SIMPLE, STRCT_SIMPLE, STRCT_SIMPLE, STRCT_SIMPLE, STRCT_SIMPLE,
    STRCT_SIMPLE, STRCT_SIMPLE, STRCT_SIMPLE, STRCT_SIMPLE, STRCT_SIMPLE, STRCT_SIMPLE,
    STRCT_SIMPLE, STRCT_SIMPLE
};

const MatchPairFunction FUNCT_PAIR[CFG_ENGINE_NCRITERIA] = {
   FNCTR_PAIR_NOP, FNCTR_PAIR_NOP, FNCTR_PAIR_NOP, FNCTR_PAIR_NOP, FNCTR_PAIR_AND, FNCTR_PAIR_AND,
   FNCTR_PAIR_NOP, FNCTR_PAIR_NOP, FNCTR_PAIR_AND, FNCTR_PAIR_NOP, FNCTR_PAIR_NOP, FNCTR_PAIR_NOP,
   FNCTR_PAIR_NOP, FNCTR_PAIR_NOP, FNCTR_PAIR_NOP, FNCTR_PAIR_NOP, FNCTR_PAIR_NOP, FNCTR_PAIR_NOP,
   FNCTR_PAIR_NOP, FNCTR_PAIR_NOP, FNCTR_PAIR_NOP, FNCTR_PAIR_NOP
};

const MatchSimpFunction FUNCT_A[CFG_ENGINE_NCRITERIA] = {
    FNCTR_SIMP_EQU, FNCTR_SIMP_EQU, FNCTR_SIMP_EQU, FNCTR_SIMP_EQU, FNCTR_SIMP_GEQ, FNCTR_SIMP_GEQ,
    FNCTR_SIMP_EQU, FNCTR_SIMP_EQU, FNCTR_SIMP_GEQ, FNCTR_SIMP_EQU, FNCTR_SIMP_EQU, FNCTR_SIMP_EQU,
    FNCTR_SIMP_EQU, FNCTR_SIMP_EQU, FNCTR_SIMP_EQU, FNCTR_SIMP_EQU, FNCTR_SIMP_EQU, FNCTR_SIMP_EQU,
    FNCTR_SIMP_EQU, FNCTR_SIMP_EQU, FNCTR_SIMP_EQU, FNCTR_SIMP_EQU
};

const MatchSimpFunction FUNCT_B[CFG_ENGINE_NCRITERIA] = {
    FNCTR_SIMP_NOP, FNCTR_SIMP_NOP, FNCTR_SIMP_NOP, FNCTR_SIMP_NOP, FNCTR_SIMP_LEQ, FNCTR_SIMP_LEQ,
    FNCTR_SIMP_NOP, FNCTR_SIMP_NOP, FNCTR_SIMP_LEQ, FNCTR_SIMP_NOP, FNCTR_SIMP_NOP, FNCTR_SIMP_NOP,
    FNCTR_SIMP_NOP, FNCTR_SIMP_NOP, FNCTR_SIMP_NOP, FNCTR_SIMP_NOP, FNCTR_SIMP_NOP, FNCTR_SIMP_NOP,
    FNCTR_SIMP_NOP, FNCTR_SIMP_NOP, FNCTR_SIMP_NOP, FNCTR_SIMP_NOP
};

const bool WILDCARD_EN[CFG_ENGINE_NCRITERIA] = {
    false, false, true, true, true, true, true, true, true, true, true, true, true, true, true,
    true, true, true, true, false, true, true
};

struct edge_s {
    uint16_t operand_a;
    uint16_t operand_b;
    uint16_t pointer;
    bool last;
};

struct result_s {
    uint32_t weight;
    uint16_t pointer;
};

struct level_s {
    uint32_t weight;
    uint64_t base;
};

edge_s*   the_memory[CFG_ENGINE_NCRITERIA];

bool functor(const MatchSimpFunction& G_FUNCTION,
             const bool& G_WILDCARD,
             const uint16_t& rule_i,
             const uint16_t& query_i,
             bool* wildcard_o)
{
    bool sig_result;

    switch(G_FUNCTION)
    {
      case FNCTR_SIMP_EQU:
            sig_result = query_i == rule_i;
            break;
      case FNCTR_SIMP_NEQ:
            sig_result = query_i != rule_i;
            break;
      case FNCTR_SIMP_GRT:
            sig_result = query_i > rule_i;
            break;
      case FNCTR_SIMP_GEQ:
            sig_result = query_i >= rule_i;
            break;
      case FNCTR_SIMP_LES:
            sig_result = query_i < rule_i;
            break;
      case FNCTR_SIMP_LEQ:
            sig_result = query_i <= rule_i;
            break;
      default:
            sig_result = false;
    }

    if (G_WILDCARD and G_FUNCTION != FNCTR_SIMP_NOP)
    {
        *wildcard_o = (rule_i == 0);
        sig_result = *wildcard_o or sig_result;
    }
    else
    {
        *wildcard_o = false;
        sig_result = sig_result;
    }

    return sig_result;
}

bool matcher(const MatchStructureType& G_STRUCTURE,
             const MatchSimpFunction& G_FUNCTION_A,
             const MatchSimpFunction& G_FUNCTION_B,
             const MatchPairFunction& G_FUNCTION_PAIR,
             const bool& G_WILDCARD,
             const uint16_t& op_query_i,
             const uint16_t& opA_rule_i,
             const uint16_t& opB_rule_i,
             bool* wildcard_o)
{
    bool sig_functorA;
    bool sig_functorB;
    bool sig_wildcard_a;
    bool sig_wildcard_b;
    bool sig_mux_pair;

    sig_functorA = functor(G_FUNCTION_A, G_WILDCARD, opA_rule_i, op_query_i, &sig_wildcard_a);

    bool match_result_o;
    switch (G_STRUCTURE)
    {
      case STRCT_SIMPLE:
            *wildcard_o = sig_wildcard_a;
            match_result_o = sig_functorA;
            break;
      case STRCT_PAIR:
            sig_functorB = functor(G_FUNCTION_B, G_WILDCARD, opB_rule_i, op_query_i, &sig_wildcard_b);

            *wildcard_o = sig_wildcard_a or sig_wildcard_b;

            switch (G_FUNCTION_PAIR)
            {
              case FNCTR_PAIR_AND:
                    sig_mux_pair = sig_functorA && sig_functorB;
                    break;
              case FNCTR_PAIR_OR:
                    sig_mux_pair = sig_functorA || sig_functorB;
                    break;
              case FNCTR_PAIR_XOR:
                    sig_mux_pair = sig_functorA ^ sig_functorB;
                    break;
              case FNCTR_PAIR_NAND:
                    sig_mux_pair = !(sig_functorA && sig_functorB);
                    break;
              case FNCTR_PAIR_NOR:
                    sig_mux_pair = !(sig_functorA || sig_functorB);
                    break;
              default:
                    sig_mux_pair = false;
            }
            match_result_o = sig_mux_pair;
            break;
      default:
            match_result_o = false;;
    }

    return match_result_o;
}

void compute(const uint16_t* query, const uint16_t level, uint16_t pointer, const uint32_t interim,
             result_s* result)
{
    uint32_t aux_interim;
    bool wildcard;
    do
    {
        bool match =  matcher(STRUCT_TYPE[level], FUNCT_A[level], FUNCT_B[level], FUNCT_PAIR[level],
            WILDCARD_EN[level], *query, 
            the_memory[level][pointer].operand_a,
            the_memory[level][pointer].operand_b,
            &wildcard);

        if (!match)
            continue;

        // weight
        if (wildcard)
            aux_interim = interim;
        else
            aux_interim = interim + WEIGHTS[level];

        // check pointer or result
        if (level == CFG_ENGINE_NCRITERIA - 1)
        {
            if (aux_interim >= result->weight)
            {
                //if ((aux_interim == result->weight) && (result->pointer != the_memory[level][pointer].pointer))
                //    printf("Weird\n");
                result->weight = aux_interim;
                result->pointer = the_memory[level][pointer].pointer;

            }
        }
        else
        {
            compute(query+1, level+1, the_memory[level][pointer].pointer, aux_interim, result);
        }
    } while(!the_memory[level][pointer++].last);
}

int main(int argc, char** argv)
{
    ////////////////////////////////////////////////////////////////////////////////////////////////
    // PARAMETERS                                                                                 //
    ////////////////////////////////////////////////////////////////////////////////////////////////

    std::cout << "# PARAMETERS" << std::endl;

    char* workload_file = NULL;
    char* nfadata_file = NULL;
    char* results_file = NULL;
    char* bnchmrk_out = NULL;
    uint32_t max_batch_size = 1<<10;
    uint32_t iterations = 100;
    uint16_t cores_number = 1;

    char opt;
    while ((opt = getopt(argc, argv, "n:w:r:o:m:i:c:h")) != -1) {
        switch (opt) {
        case 'n':
            nfadata_file = (char*) malloc(strlen(optarg)+1);
            strcpy(nfadata_file, optarg);
            break;
        case 'w':
            workload_file = (char*) malloc(strlen(optarg)+1);
            strcpy(workload_file, optarg);
            break;
        case 'r':
            results_file = (char*) malloc(strlen(optarg)+1);
            strcpy(results_file, optarg);
            break;
        case 'o':
            bnchmrk_out = (char*) malloc(strlen(optarg)+1);
            strcpy(bnchmrk_out, optarg);
            break;
        case 'm':
            max_batch_size = atoi(optarg);
            break;
        case 'i':
            iterations = atoi(optarg);
            break;
        case 'c':
            cores_number = atoi(optarg);
            break;
        case 'h':
        default: /* '?' */
            std::cerr << "Usage: " << argv[0] << "\n"
                      << "\t-n  nfa_data_file\n"
                      << "\t-w  workload_file\n"
                      << "\t-r  result_data_file\n"
                      << "\t-o  benchmark_out_file\n"
                      << "\t-m  max_batch_size\n"
                      << "\t-i  iterations\n"
                      << "\t-c  cores_number\n"
                      << "\t-h  help\n";
            return EXIT_FAILURE;
        }
    }

    printf("-n nfa_data_file: %s\n", nfadata_file);
    printf("-w workload_file: %s\n", workload_file);
    printf("-r result_data_file: %s\n", results_file);
    printf("-o benchmark_out_file: %s\n", bnchmrk_out);
    printf("-m max_batch_size: %u\n", max_batch_size);
    printf("-i iterations: %u\n", iterations);
    printf("-c cores_number: %u\n", cores_number);

    ////////////////////////////////////////////////////////////////////////////////////////////////
    // NFA SETUP                                                                                  //
    ////////////////////////////////////////////////////////////////////////////////////////////////
    std::cout << "# NFA SETUP" << std::endl;

    std::ifstream file_nfadata(nfadata_file, std::ios::in | std::ios::binary);
    if(file_nfadata.is_open())
    {
        uint32_t num_edges;
        uint64_t raw_edge;
        uint16_t padding;
        uint64_t  nfa_hash;

        file_nfadata.read(reinterpret_cast<char *>(&nfa_hash), sizeof(nfa_hash));

        for (uint16_t level=0; level<CFG_ENGINE_NCRITERIA; level++)
        {
            file_nfadata.read(reinterpret_cast<char *>(&raw_edge), sizeof(raw_edge));
            num_edges = raw_edge;
            the_memory[level] = (edge_s*) malloc(num_edges * sizeof(edge_s));
            //std::cout << " level=" << level << " edges=" << num_edges << std::endl;

            for (uint32_t i=0; i<num_edges; i++)
            {
                file_nfadata.read(reinterpret_cast<char *>(&raw_edge), sizeof(raw_edge));
                the_memory[level][i].operand_a = (raw_edge >> SHIFT_OPERAND_A) & MASK_OPERAND_A;
                the_memory[level][i].operand_b = (raw_edge >> SHIFT_OPERAND_B) & MASK_OPERAND_B;
                the_memory[level][i].pointer = (raw_edge >> SHIFT_POINTER) & MASK_POINTER;
                the_memory[level][i].last = (raw_edge >> SHIFT_LAST) & 1;
            }

            // Padding
            padding = (num_edges + 1) % C_EDGES_PER_CACHE_LINE;
            padding = (padding == 0) ? 0 : C_EDGES_PER_CACHE_LINE - padding;
            file_nfadata.seekg(padding * sizeof(raw_edge), std::ios::cur);
        }
        file_nfadata.seekg(0, std::ios::end);
        const uint32_t raw_size = ((uint32_t)file_nfadata.tellg()) - sizeof(nfa_hash);
        printf("> NFA size: %u bytes\n", raw_size);
        printf("> NFA hash: %lu\n", nfa_hash);
        file_nfadata.close();
    }
    else
    {
        printf("[!] Failed to open NFA .bin file\n");
        return EXIT_FAILURE;
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////
    // WORKLOAD SETUP                                                                             //
    ////////////////////////////////////////////////////////////////////////////////////////////////
    std::cout << "# WORKLOAD SETUP" << std::endl;

    char*    workload_buff;
    uint32_t workload_size; // in queries
    uint32_t query_size;    // in bytes with padding
    uint32_t results_size;  // in bytes without padding

    std::ifstream queries_file(workload_file, std::ios::in | std::ios::binary);
    if(queries_file.is_open())
    {
        queries_file.seekg(0, std::ios::end);
        const uint32_t raw_size = ((uint32_t)queries_file.tellg()) - 2 * sizeof(query_size);

        queries_file.seekg(0, std::ios::beg);
        queries_file.read(reinterpret_cast<char *>(&query_size), sizeof(query_size));
        queries_file.read(reinterpret_cast<char *>(&workload_size), sizeof(workload_size));

        if (workload_size * query_size != raw_size)
        {
            printf("[!] Corrupted benchmark file!\n[!]  Expected: %u bytes\n[!]  Got: %u bytes\n",
                workload_size * query_size, raw_size);
            fflush(stdout);
            return EXIT_FAILURE;
        }

        workload_buff = new char[raw_size];
        queries_file.read(workload_buff, raw_size);
        queries_file.close();
    }
    else
    {
        printf("[!] Failed to open BENCHMARK .bin file\n"); fflush(stdout);
        return EXIT_FAILURE;
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////
    // MULTIPLE BATCH SIZES 2^N                                                                   //
    ////////////////////////////////////////////////////////////////////////////////////////////////

    std::ofstream file_bnchout(bnchmrk_out);
    file_bnchout << "batch_size,total_ns" << std::endl;

    operands_t* the_queries;
    uint32_t aux;

    for (uint32_t bsize = 1; bsize < max_batch_size; bsize = bsize << 1)
    {
        the_queries = (operands_t*) malloc(bsize * CFG_ENGINE_NCRITERIA * sizeof(operands_t));
        result_s* results = (result_s*) calloc(bsize, sizeof(*results));
        results_size = bsize * sizeof(operands_t);
        
        printf("> # of queries: %9u\n", bsize);
        printf("> Queries size: %9u bytes\n", bsize * query_size);
        printf("> Results size: %9u bytes\n", results_size);

        for (uint32_t i = 0; i < iterations; i++)
        {
            for (uint32_t k = 0; k < bsize; k++)
            {
                aux = (rand() % workload_size) * query_size;
                memcpy(&the_queries[k*CFG_ENGINE_NCRITERIA], &(workload_buff[aux]), CFG_ENGINE_NCRITERIA * sizeof(operands_t));
            }

            ////////////////////////////////////////////////////////////////////////////////////////
            // KERNEL EXECUTION                                                                   //
            ////////////////////////////////////////////////////////////////////////////////////////

            // std::chrono::time_point<std::chrono::high_resolution_clock>* starts;
            // std::chrono::time_point<std::chrono::high_resolution_clock>* ends;
            // starts = (std::chrono::time_point<std::chrono::high_resolution_clock>*)
            //                                                 calloc(bsize, sizeof(*starts));
            // ends = (std::chrono::time_point<std::chrono::high_resolution_clock>*)
            //                                                 calloc(bsize, sizeof(*ends));

            auto start = std::chrono::high_resolution_clock::now();
            #pragma omp parallel for num_threads(cores_number)
            for (uint32_t query=0; query < bsize; query++)
            {
                // starts[query] = std::chrono::high_resolution_clock::now();
                compute(&the_queries[query * CFG_ENGINE_NCRITERIA],
                        0, // level
                        the_queries[query * CFG_ENGINE_NCRITERIA], // pointer
                        0, // interim
                        &results[query]);
                // ends[query] = std::chrono::high_resolution_clock::now();
            }
            auto finish = std::chrono::high_resolution_clock::now();
            std::chrono::duration<double, std::nano> elapsed = finish - start;

            file_bnchout << bsize << "," << elapsed.count() << std::endl;
        }
        free(the_queries);
        free(results);
    }
    delete [] workload_buff;

    ////////////////////////////////////////////////////////////////////////////////////////////////
    // RESULTS                                                                                    //
    ////////////////////////////////////////////////////////////////////////////////////////////////

    // std::ofstream results_file(argv[3]);
    // char buffer[50];
// 
//     // for (uint i = 0; i < bsize; ++i)
//     // {
//     //     std::chrono::duration<double> elapsed = ends[i] - starts[i];
//     //     sprintf(buffer, "%u,%.6lf\n", results[i].pointer, elapsed.count()*1000);
//     //     results_file << buffer;
    // }

    // TODO memory releases!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

    return EXIT_SUCCESS;
}